//
//  LCLaunchPlaceholder.swift
//  LiveContainerSwiftUI
//
//  What a guest window shows before its app has drawn anything.
//
//  iOS never leaves you on the home screen after a tap: it grows the app's launch
//  screen out of the icon within a frame or two — SpringBoard has the launch
//  assets without the app process being up — and the real interface replaces it
//  silently later. Nothing waits, because what opens immediately is not the app
//  yet. A guest here is in the same position: its bundle is on disk and readable
//  long before its process has rendered.
//
//  So the window opens at once carrying one of these, and drops it once the guest
//  has content of its own behind it.
//

import UIKit

enum LCLaunchPlaceholder {

    /// A stand-in for `appInfo`'s first frame, or nil when there is nothing
    /// sensible to draw — in which case the window opens as it always did.
    ///
    /// Preference goes to the app's declared launch screen, which is what iOS
    /// itself would put on screen. Apps that declare none get their icon on a
    /// plain field: not what iOS shows, but it names the app that is opening,
    /// which is the whole job of the frame before the first one.
    static func view(for appInfo: LCAppInfo?) -> UIView? {
        guard let appInfo else { return nil }
        let bundle = appInfo.bundlePath().flatMap { Bundle(path: $0) }
        let placeholder = LaunchPlaceholderView()

        if let launchScreen = appInfo.info()?["UILaunchScreen"] as? [String: Any] {
            // Read out of the guest's bundle rather than loaded from its code, so
            // none of it depends on the guest process being up — which is the
            // point, since it is not. An empty declaration is legitimate and
            // common, and means what it says: a plain field.
            if let colorName = launchScreen["UIColorName"] as? String,
               let color = UIColor(named: colorName, in: bundle, compatibleWith: nil) {
                placeholder.backgroundColor = color
            }
            if let imageName = launchScreen["UIImageName"] as? String,
               let image = UIImage(named: imageName, in: bundle, compatibleWith: nil) {
                placeholder.show(image, cornerRatio: 0, maxSide: .greatestFiniteMagnitude)
            }
        } else if let icon = appInfo.iconIsDarkIcon(false) {
            // No launch screen declared: the app's own icon, at the springboard's
            // corner proportion so it reads as the icon that was just pressed.
            placeholder.show(icon, cornerRatio: 0.2237, maxSide: 120)
        }
        return placeholder
    }
}

/// Lays its content out from its own bounds every time they change.
///
/// A window is handed its placeholder while it is still being built, before
/// anyone has told it how big it is going to be, and it is then flown from icon
/// size to full screen. Nothing here may depend on the size it had when it was
/// made.
private final class LaunchPlaceholderView: UIView {

    private let imageView = UIImageView()
    private var cornerRatio: CGFloat = 0
    private var maxSide: CGFloat = .greatestFiniteMagnitude

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        // Opaque in its own right: what the window puts behind it is a black
        // letterbox backdrop, which must not show through.
        backgroundColor = .systemBackground
        imageView.contentMode = .scaleAspectFit
        imageView.isHidden = true
        imageView.clipsToBounds = true
        imageView.layer.cornerCurve = .continuous
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ image: UIImage, cornerRatio: CGFloat, maxSide: CGFloat) {
        imageView.image = image
        imageView.isHidden = false
        self.cornerRatio = cornerRatio
        self.maxSide = maxSide
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image, !imageView.isHidden else { return }

        // Its natural size, shrunk to fit and to whatever cap this kind of image
        // has — a launch image is drawn as authored, an icon at icon size.
        let limit = CGSize(width: min(bounds.width, maxSide), height: min(bounds.height, maxSide))
        let natural = image.size
        guard natural.width > 0, natural.height > 0, limit.width > 0, limit.height > 0 else { return }
        let scale = min(1, min(limit.width / natural.width, limit.height / natural.height))
        let size = CGSize(width: natural.width * scale, height: natural.height * scale)

        imageView.frame = CGRect(x: bounds.midX - size.width / 2,
                                 y: bounds.midY - size.height / 2,
                                 width: size.width,
                                 height: size.height)
        imageView.layer.cornerRadius = min(size.width, size.height) * cornerRatio
    }
}
