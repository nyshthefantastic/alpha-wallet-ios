// Copyright © 2021 Stormbird PTE. LTD.

import UIKit
import WebKit
import Kingfisher
import AlphaWalletFoundation
import Combine

final class FixedContentModeImageView: UIImageView {
    var fixedContentMode: UIView.ContentMode {
        didSet { self.layoutSubviews() }
    }

    var rounding: ViewRounding = .none {
        didSet { layoutSubviews() }
    }

    init(fixedContentMode contentMode: UIView.ContentMode) {
        self.fixedContentMode = contentMode
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        contentMode = fixedContentMode
        layer.masksToBounds = true
        clipsToBounds = true
        backgroundColor = Configuration.Color.Semantic.defaultViewBackground

        cornerRadius = rounding.cornerRadius(view: self)
    }
}

//TODO: move later most of logic from app coordinator here
class App {
    let imageLoader: ImageLoader = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60

        let session = URLSession(configuration: configuration)
        let cache = KingfisherImageCacheStore()

        return ImageLoader(
            session: session,
            cache: cache,
            interceptor: AvAssetImageLoaderResponseInterceptor(cache: cache))
    }()

    static let shared: App = App()

    private init() {}
}

//TODO: rename maybe, as its actually not image view
final class WebImageView: UIView, ContentBackgroundSupportable {
    
    private lazy var placeholderImageView: FixedContentModeImageView = {
        let imageView = FixedContentModeImageView(fixedContentMode: contentMode)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.backgroundColor = backgroundColor
        imageView.isHidden = true
        imageView.rounding = .none
        
        return imageView
    }()
    
    private lazy var imageView: FixedContentModeImageView = {
        let imageView = FixedContentModeImageView(fixedContentMode: contentMode)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.backgroundColor = backgroundColor
        
        return imageView
    }()
    
    private lazy var svgImageView: SvgImageView = {
        let imageView = SvgImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.rounding = rounding
        imageView.backgroundColor = backgroundColor
        return imageView
    }()

    private lazy var videoPlayerView: AVPlayerView = {
        let view = AVPlayerView()
        view.translatesAutoresizingMaskIntoConstraints = false

        return view
    }()
    
    override var contentMode: UIView.ContentMode {
        didSet { imageView.fixedContentMode = contentMode }
    }
    
    var rounding: ViewRounding = .none {
        didSet { imageView.rounding = rounding; svgImageView.rounding = rounding; videoPlayerView.rounding = rounding; }
    }
    
    var contentBackgroundColor: UIColor? {
        didSet { imageView.backgroundColor = contentBackgroundColor; }
    }

    private let imageLoader: ImageLoader
    private let loadContentSubject = PassthroughSubject<LoadUrlEvent, Never>()
    private var cancellable = Set<AnyCancellable>()

    init(edgeInsets: UIEdgeInsets = .zero, imageLoader: ImageLoader = App.shared.imageLoader) {
        self.imageLoader = imageLoader
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = true
        
        addSubview(imageView)
        addSubview(svgImageView)
        addSubview(placeholderImageView)
        addSubview(videoPlayerView)
        
        NSLayoutConstraint.activate([
            videoPlayerView.anchorsConstraint(to: self, edgeInsets: edgeInsets),
            svgImageView.anchorsConstraint(to: self, edgeInsets: edgeInsets),
            placeholderImageView.anchorsConstraint(to: self, edgeInsets: edgeInsets),
            imageView.anchorsConstraint(to: self, edgeInsets: edgeInsets)
        ])

        let emptyUrl = URL(string: "no-url")!
        //TODO: replace later with WebImageView.ViewState
        typealias DebugViewState = (viewState: WebImageView.ViewState, url: URL)

        loadContentSubject
            .removeDuplicates()
            .flatMapLatest { [imageLoader] event -> AnyPublisher<DebugViewState, Never> in
                switch event {
                case .image(let image):
                    guard let image = image else {
                        return .just((viewState: ViewState.noContent, url: emptyUrl))
                    }

                    return .just((viewState: ViewState.content(.image(image)), url: emptyUrl))
                case .url(let url):
                    guard let url = url else {
                        return .just((viewState: ViewState.noContent, url: emptyUrl))
                    }

                    return imageLoader.fetch(url)
                        .map { state -> DebugViewState in
                            switch state {
                            case .loading:
                                return (viewState: ViewState.loading, url: url)
                            case .done(let value):
                                return (viewState: ViewState.content(value), url: url)
                            case .failure://Not applicatable here, as publisher returns can failure, handled in `replaceError`
                                return (viewState: ViewState.noContent, url: url)
                            }
                        }.replaceError(with: (viewState: ViewState.noContent, url: url))
                        .eraseToAnyPublisher()
                case .cancel:
                    return .just((viewState: ViewState.noContent, url: emptyUrl))
                }
            }.print("xxx.viewState")
            .sink { [weak self] in self?.reload(viewState: $0.viewState, for: $0.url) }
            .store(in: &cancellable)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setImage(image: UIImage?, placeholder: UIImage? = R.image.tokenPlaceholderLarge()) {
        placeholderImageView.image = placeholder
        loadContentSubject.send(.image(image))
    }

    func setImage(url: WebImageURL?, placeholder: UIImage? = R.image.tokenPlaceholderLarge()) {
        placeholderImageView.image = placeholder

        loadContentSubject.send(.url(url?.url))
    }

    private func reload(viewState: ViewState, for url: URL) {
        switch viewState {
        case .loading:
            svgImageView.alpha = 0
            imageView.image = nil
            videoPlayerView.alpha = 0
            placeholderImageView.isHidden = false
        case .noContent:
            svgImageView.alpha = 0
            imageView.image = nil
            videoPlayerView.alpha = 0

            placeholderImageView.isHidden = false
        case .content(let data):
            switch data {
            case .svg(let svg):
                imageView.image = nil
                svgImageView.setImage(svg: svg)
                //TODO: subscribe for pageHasLoaded updates, to hide preview view when page has loaded, and same for video played later
                placeholderImageView.isHidden = true//!svgImageView.pageHasLoaded
            case .image(let image):
                imageView.image = image

                svgImageView.alpha = 0
                videoPlayerView.alpha = 0
                placeholderImageView.isHidden = true
            case .video(let video):
                svgImageView.alpha = 0
                videoPlayerView.alpha = 1

                imageView.image = video.preview
                placeholderImageView.isHidden = video.preview != nil

                videoPlayerView.play(url: video.url)
            }
        }
    }

    func cancel() {
        loadContentSubject.send(.cancel)
    }
}

extension WebImageView {
    private enum LoadUrlEvent: Equatable {
        case url(URL?)
        case image(UIImage?)
        case cancel
    }

    private enum ViewState: CustomStringConvertible {
        case noContent
        case loading
        case content(ImageLoader.ImageOrSvg)

        var description: String {
            switch self {
            case .loading:
                return "ViewState.loading"
            case .noContent:
                return "ViewState.emptyContent"
            case .content(let data):
                switch data {
                case .image:
                    return "ViewState.image"
                case .video:
                    return "ViewState.video"
                case .svg:
                    return "ViewState.svg"
                }
            }
        }
    }
}
