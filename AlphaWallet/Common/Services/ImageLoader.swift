//
//  ImageLoader.swift
//  AlphaWallet
//
//  Created by Vladyslav Shepitko on 01.02.2023.
//

import UIKit
import Combine
import AVKit
import Kingfisher
import AlphaWalletFoundation

protocol ImageCacheStore: AnyObject {
    func value(for key: String) throws -> Data?
    func set(data: Data, for key: String) throws
}

final class KingfisherImageCacheStore: ImageCacheStore {
    private let diskStorage = ImageCache(name: "aw-cache-store").diskStorage

    func value(for key: String) throws -> Data? {
        try diskStorage.value(forKey: key)
    }

    func set(data: Data, for key: String) throws {
        try diskStorage.store(value: data, forKey: key)
    }
}

protocol ImageLoaderResponseInterceptor: AnyObject {
    func intercept(response: ImageLoader.ImageOrSvg) -> ImageLoader.LoadContentPublisher
}

fileprivate enum ImageCacheKey: CaseIterable {
    case raw
    case videoPreview

    static func cacheKey(for url: URL, prefix: ImageCacheKey) -> String {
        switch prefix {
        case .raw:
            return url.absoluteString
        case .videoPreview:
            return "video-preview-\(url.absoluteString)"
        }
    }
}

class AvAssetImageLoaderResponseInterceptor: ImageLoaderResponseInterceptor {
    private let cache: ImageCacheStore

    var compressedImageSize: CGSize = CGSize(width: 400, height: 400)

    init(cache: ImageCacheStore) {
        self.cache = cache
    }

    func intercept(response: ImageLoader.ImageOrSvg) -> ImageLoader.LoadContentPublisher {
        switch response {
        case .svg, .image:
            return .just(.done(response))
        case .video(let video):
            return AVAsset(url: video.url)
                .extractUIImageAsync(size: compressedImageSize)
                .map { [cache] preview -> Loadable<ImageLoader.ImageOrSvg, ImageLoader.NoError> in
                    guard let preview = preview, let pngData = preview.pngData() else { return .done(.video(video)) }

                    let video = ImageLoader.Video(url: video.url, preview: preview)
                    try? cache.set(data: pngData, for: ImageCacheKey.cacheKey(for: video.url, prefix: .videoPreview))

                    return .done(.video(video))
                }.replaceError(with: .done(.video(video)))
                .setFailureType(to: ImageLoader.ImageLoaderError.self)
                .eraseToAnyPublisher()
        }
    }
}

final class ImageLoader {
    private let queue = DispatchQueue(label: "org.alphawallet.swift.imageLoader.processingQueue", qos: .utility)
    private var publishers: [URLRequest: LoadContentPublisher]
    private let session: URLSession
    private let cache: ImageCacheStore
    private let decoder: ImageDecoder
    private let interceptor: ImageLoaderResponseInterceptor
    private let base64Decoder = Base64Decoder()

    init(publishers: [URLRequest: LoadContentPublisher] = [:],
         session: URLSession,
         cache: ImageCacheStore,
         decoder: ImageDecoder = ImageDecoder(),
         interceptor: ImageLoaderResponseInterceptor) {

        self.decoder = decoder
        self.interceptor = interceptor
        self.cache = cache
        self.publishers = publishers
        self.session = session
    }

    //NOTE: we receive can receive base64 as url, so we need to decode it first and return right data
    //treat value from base64 as string to display in webview, might be needed to handle special mime types
    //or maybe its better to handle decoding base64 when return image for token, make special manager for it, not just static func like it is for now
    public func fetch(_ url: URL) -> LoadContentPublisher {
        if let data = base64Decoder.decode(string: url.absoluteString), data.mimeType != nil, let string = String(data: data.data, encoding: .utf8) {
            return .just(.done(.svg(string))).prepend(.loading).eraseToAnyPublisher()
        } else {
            let request = URLRequest(url: url)
            return fetch(request)
        }
    }

    public func fetch(_ urlRequest: URLRequest) -> LoadContentPublisher {
        return buildFetchPublisher(urlRequest)
            .prepend(.loading)
            .eraseToAnyPublisher()
    }

    private func buildFetchPublisher(_ urlRequest: URLRequest) -> LoadContentPublisher {
        guard let url = urlRequest.url else { return .fail(.invalidUrl) }

        if let data = try? cache.value(for: ImageCacheKey.cacheKey(for: url, prefix: .raw)), let data = try? decoder.decode(data: data) {
            switch data {
            case .image, .svg:
                return .just(.done(data))
            case .video(let video):
                let preview = try? cache.value(for: ImageCacheKey.cacheKey(for: url, prefix: .videoPreview)).flatMap { UIImage(data: $0) }
                let video = Video(url: video.url, preview: preview)

                return .just(.done(.video(video)))
            }
        }

        return Just(urlRequest)
            .receive(on: queue)
            .setFailureType(to: ImageLoaderError.self)
            .flatMap { [weak self, queue, session, cache, decoder, interceptor] urlRequest -> LoadContentPublisher in
                if let publisher = self?.publishers[urlRequest] {
                    return publisher
                } else {
                    let publisher = session.dataTaskPublisher(for: urlRequest)
                        .receive(on: queue)
                        .mapError { ImageLoaderError.internal($0) }
                        .flatMap { response -> LoadContentPublisher in
                            do {
                                guard let httpResponse = response.response as? HTTPURLResponse else { throw ImageLoaderError.invalidData }
                                let value = try decoder.decode(response: httpResponse, data: response.data) as! ImageDecoder.Response
                                try cache.set(data: value.data, for: ImageCacheKey.cacheKey(for: url, prefix: .raw))

                                return interceptor.intercept(response: value.image)
                            } catch {
                                return .fail(ImageLoaderError.invalidData)
                            }
                        }.share()
                        .handleEvents(receiveCompletion: { _ in self?.publishers[urlRequest] = nil })
                        .receive(on: RunLoop.main)
                        .eraseToAnyPublisher()

                    self?.publishers[urlRequest] = publisher

                    return publisher
                }
            }.eraseToAnyPublisher()
    }
}

extension ImageLoader {
    typealias LoadContentPublisher = AnyPublisher<Loadable<ImageOrSvg, NoError>, ImageLoaderError>

    struct NoError: Error {}

    enum ImageLoaderError: Error {
        case `internal`(Error)
        case invalidData
        case invalidUrl
    }

    enum ImageOrSvg {
        case image(UIImage)
        case svg(String)
        case video(Video)
    }

    struct Video {
        let url: URL
        let preview: UIImage?
    }

    private struct VideoUrl: Codable {
        let url: URL
    }

    struct ImageDecoder: AnyDecoder {
        typealias Response = (data: Data, image: ImageOrSvg)
        var contentType: String? { return nil }

        private func isValidResponse(statusCode: Int) -> Bool {
            return (200...299).contains(statusCode)
        }

        func decode(response: HTTPURLResponse, data: Data) throws -> Any {
            guard let url = response.url else { throw DecoderError.responseUrlNotFound }
            guard isValidResponse(statusCode: response.statusCode) else { throw DecoderError.invalidStatusCode(response.statusCode) }
            guard !data.isEmpty else { throw DecoderError.emptyDataResponse }

            return try decode(data: data, url: url)
        }

        enum DecoderError: Error {
            case decodeFailure(data: Data)
            case emptyDataResponse
            case responseUrlNotFound
            case invalidStatusCode(Int)
        }

        func decode(data: Data) throws -> ImageOrSvg {
            if let image = UIImage(data: data) {
                return .image(image)
            } else if let data = try? JSONDecoder().decode(VideoUrl.self, from: data) {
                return .video(.init(url: data.url, preview: nil))
            } else if let svg = String(data: data, encoding: .utf8) {
                return .svg(svg)
            } else {
                throw DecoderError.decodeFailure(data: data)
            }
        }

        private func decode(data: Data, url: URL) throws -> Response {
            if let image = UIImage(data: data) {
                return (data: data, .image(image))
            } else if let svg = String(data: data, encoding: .utf8) {
                return (data: data, .svg(svg))
            } else {
                let data = try JSONEncoder().encode(VideoUrl(url: url))
                return (data: data, .video(.init(url: url, preview: nil)))
            }
        }
    }
}
