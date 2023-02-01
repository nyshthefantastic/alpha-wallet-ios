//
//  AVPlayerView.swift
//  AlphaWallet
//
//  Created by Vladyslav Shepitko on 01.02.2023.
//

import UIKit
import AVKit
import Combine

class AVPlayerView: UIView, ViewRoundingSupportable {

    override class var layerClass: AnyClass {
        return AVPlayerLayer.self
    }

    var videoLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    private let player = AVPlayer()
    private var cancelable = Set<AnyCancellable>()
    private let urlSubject = PassthroughSubject<URL, Never>()
    private let cache: ImageCacheStore

    var rounding: ViewRounding = .none {
        didSet { layoutSubviews() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        cornerRadius = rounding.cornerRadius(view: self)
    }

    init(cache: ImageCacheStore = KingfisherImageCacheStore()) {
        self.cache = cache

        super.init(frame: .zero)
        videoLayer.videoGravity = .resizeAspectFill
        videoLayer.player = player
        player.actionAtItemEnd = .none

        urlSubject
            .flatMapLatest { [player] url in
                let asset = AVAsset(url: url)
                return asset.loadValuesAsync()
                    .print("xxx.loadValuesAsync")
                    .handleEvents(receiveOutput: { state in
                        switch state {
                        case .loading:
                            break
                        case .loaded(let item):
                            player.replaceCurrentItem(with: item)
                            player.play()
                        }
                    }).mapToVoid()
                    .replaceError(with: ())
            }.sink(receiveCompletion: { _ in

            }, receiveValue: { _ in

            }).store(in: &cancelable)

        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .sink { [player] _ in player.seek(to: CMTime.zero) }
            .store(in: &cancelable)

//                NotificationCenter.default.addObserver(self,
//                                                       selector: #selector(playerItemDidReachEnd(notification:)),
//                                                       name: .AVPlayerItemDidPlayToEndTime,
//                                                       object: player.currentItem)

//        player.publisher(for: \.status, options: [.initial, .new])
//            .print("xxx.status")
//            .sink { status in
//                switch status {
//                case .readyToPlay:
//                    break
//                case .unknown, .failed:
//                    break
//                @unknown default:
//                    break
//                }
//            }.store(in: &cancelable)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func play(url: URL) {
        urlSubject.send(url)

//        return playerState
//        print("xxx.player.play: \(url)")
//        self.url = url

//        let asset = AVAsset(url: url)
//        let item = AVPlayerItem(asset: asset)

//        player.replaceCurrentItem(with: item)
//        player.play()

//        let playableKey = "playable"
//        asset.cancelLoading()

//        asset.loadValuesAsynchronously(forKeys: [playableKey]) {
//            var error: NSError? = nil
//
//            let status = asset.statusOfValue(forKey: playableKey, error: &error)
//
//            switch status {
//
//            case .loaded:
//                debugPrint("Sucessfuly loaded")
////                self.playerItem = AVPlayerItem(asset: asset)
////                self.playerItem?.addObserver(self, forKeyPath: #keyPath(AVPlayerItem.status), options: [.old, .new], context: &audioPlayerInterfaceViewControllerKVOContext)
////                self.playerItem?.addObserver(self, forKeyPath: #keyPath(AVPlayerItem.duration), options: [.new, .initial], context: &audioPlayerInterfaceViewControllerKVOContext)
////                self.player = AVPlayer(playerItem: self.playerItem)
////                let interval = CMTimeMake(1, 1)
////                self.timeObserveToken = self.player.addPeriodicTimeObserver(forInterval: interval, queue: DispatchQueue.main) { [unowned self] time in
////                    let timeElapsed = Float(CMTimeGetSeconds(time))
////                    UIView.animate(withDuration: 1.5, animations: {
////                        self.durationSlider.setValue(Float(timeElapsed), animated: true)
////
////                    })
////                    self.startTimeLabel.text = self.createTimeString(time: timeElapsed)
////                }
//
//                break
//
//                    // Sucessfully loaded. Continue processing.
//
//            case .failed:
////                self.showErrorAlert(errorString: "Failed to load")
//                debugPrint("failed")
//                break
//
//                    // Handle error
//
//            case .cancelled:
////                self.showErrorAlert(errorString: "Failed to load")
//                debugPrint("Cancelled")
//                break
//
//                    // Terminate processing
//
//            default:
//                debugPrint("Error occured")
////                self.showErrorAlert(errorString: "Failed to load")
//                break
//
//                    // Handle all other cases
//            }
//        }

//        fatalError()
    }
}

extension AVAsset {

    enum ImageGeneratorError: Error {
        case `internal`(Error)
    }

    private func _generator(size: CGSize) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: self)
        generator.maximumSize = size
        generator.appliesPreferredTrackTransform = true
        return generator
    }

    enum AVAssetError: Error {
        case general(Error)
        case unknown
        case cancelled
    }

    enum AVAssetLoadingState {
        case loading
        case loaded(AVPlayerItem)
    }

    func loadValuesAsync() -> AnyPublisher<AVAssetLoadingState, AVAssetError> {
        let asset = self
        let playableKey = "playable"
        let durationKey = "duration"

        return AnyPublisher<AVAssetLoadingState, AVAssetError>.create { seal in
            asset.loadValuesAsynchronously(forKeys: [playableKey, durationKey]) {
                DispatchQueue.main.async {
                    var error: NSError? = nil
                    let status = asset.statusOfValue(forKey: playableKey, error: &error)

                    switch status {
                    case .loading:
                        seal.send(.loading)
                    case .loaded:
                        let playerItem = AVPlayerItem(asset: asset)
                        seal.send(.loaded(playerItem))
                        seal.send(completion: .finished)
                    case .failed:
                        let error = error.flatMap { AVAssetError.general($0) } ?? .unknown

                        seal.send(completion: .failure(error))
                    case .cancelled:
                        seal.send(completion: .failure(.cancelled))
                    case .unknown:
                        seal.send(completion: .failure(.unknown))
                    @unknown default:
                        seal.send(completion: .failure(.unknown))
                    }
                }
            }

            return AnyCancellable {
                asset.cancelLoading()
            }
        }
    }

    func extractUIImageAsync(size: CGSize) -> AnyPublisher<UIImage?, ImageGeneratorError> {
        let generator = _generator(size: size)
        return AnyPublisher<UIImage?, ImageGeneratorError>.create { observer in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { (_, image, _, _, error) in
                DispatchQueue.main.async {
                    if let error = error {
                        observer.send(completion: .failure(.internal(error)))
                        return
                    }
                    observer.send(image.map(UIImage.init(cgImage:)))
                    observer.send(completion: .finished)
                }
            }

            return AnyCancellable {
                generator.cancelAllCGImageGeneration()
            }
        }
    }
}
