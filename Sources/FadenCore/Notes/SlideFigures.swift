import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Finds the figures on slide pages (embedded images and vector drawings such as diagrams, tables and
/// call-outs) and renders each page's figures as one cropped JPEG. Text-only pages get no figure, so they
/// can be sent as text alone, which costs far fewer tokens than a rendered page.
enum SlideFigures {
    /// A page with fewer painted paths than this and no images has no figure (an underline or a box
    /// around a sentence isn't one).
    static let minPaths = 3
    /// Paths smaller than this in both directions (bullets, tiny icons) don't count towards `minPaths`.
    static let minPathSize: CGFloat = 8
    /// The same image, or a path, at the same place on more than half of a deck's pages (logos, header
    /// bars) is the template, not content. Images must have the same content too, so a scanned deck with
    /// a full-page image on every page keeps them all. Only applied to decks with at least this many pages.
    static let templateMinPages = 4
    /// Every image stays within 2000 px per side, the API's limit once a request has more than 20 images.
    static let maxEdge: CGFloat = 2000
    /// Raster images are rendered at their own resolution, within these scales (1 = 72 dpi).
    static let minScale: CGFloat = 1, maxScale: CGFloat = 2
    /// Vector-only figures are rendered at 108 dpi, sharp enough for diagram labels.
    static let vectorScale: CGFloat = 1.5
    static let padding: CGFloat = 6
    static let jpegQuality = 0.85

    /// One JPEG per page, or nil for pages without a figure.
    static func figures(_ url: URL) throws -> [Data?] {
        guard let document = CGPDFDocument(url as CFURL) else {
            throw SlideInputError.unreadablePDF(url.lastPathComponent)
        }
        let pages = (0..<document.numberOfPages).map { document.page(at: $0 + 1) }
        let marks = pages.map { $0.map(Marks.init(page:)) }
        let template = templateRects(marks.compactMap { $0 })
        return zip(pages, marks).map { page, marks -> Data? in
            guard let page, let marks else { return nil }
            let images = marks.images.filter { !template.contains(key($0)) }
            let paths = marks.paths.filter { !template.contains(key($0)) }
            let countedPaths = paths.filter { $0.width >= minPathSize || $0.height >= minPathSize }
            guard !images.isEmpty || countedPaths.count >= minPaths else { return nil }
            let scale = images.isEmpty
                ? vectorScale
                : min(max(images.map(\.scale).max() ?? minScale, minScale), maxScale)
            let area = (images.map(\.rect) + paths).reduce(CGRect.null) { $0.union($1) }
            return render(page, area: area.insetBy(dx: -padding, dy: -padding), scale: scale)
        }
    }

    // MARK: Template

    private static func key(_ r: CGRect) -> [Int] {
        [r.minX, r.minY, r.width, r.height].map { Int($0.rounded()) }
    }

    private static func key(_ image: Marks.Image) -> [Int] {
        key(image.rect) + [image.content]
    }

    private static func templateRects(_ pages: [Marks]) -> Set<[Int]> {
        guard pages.count >= templateMinPages else { return [] }
        var counts: [[Int]: Int] = [:]
        for page in pages {
            for k in Set(page.images.map(key) + page.paths.map(key)) { counts[k, default: 0] += 1 }
        }
        return Set(counts.filter { $0.value * 2 > pages.count }.keys)
    }

    // MARK: Rendering

    /// Renders `area` (page space) of the page on white. Rotated pages are rendered whole and upright.
    private static func render(_ page: CGPDFPage, area: CGRect, scale: CGFloat) -> Data? {
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        var crop = page.rotationAngle == 0 ? area.intersection(box) : box
        if crop.isNull || crop.isEmpty { crop = box }
        let size = rotated ? CGSize(width: crop.height, height: crop.width) : crop.size
        let s = min(scale, maxEdge / max(size.width, size.height))
        let width = Int((size.width * s).rounded()), height = Int((size.height * s).rounded())
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        if page.rotationAngle == 0 {
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: -crop.minX, y: -crop.minY)
        } else {
            ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: width, height: height),
                                                     rotate: 0, preserveAspectRatio: true))
        }
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

// MARK: - Content stream scan

/// The images and painted paths a page draws, in page space. Form XObjects are followed; inline
/// images and shadings are ignored (rare on slides, and shadings are mostly backgrounds).
private final class Marks {
    struct Image {
        var rect: CGRect
        var scale: CGFloat
        /// Identifies the image's data, so the same image on several pages can be recognised.
        var content: Int
    }

    var images: [Image] = []
    var paths: [CGRect] = []

    private var ctm = CGAffineTransform.identity
    private var stack: [CGAffineTransform] = []
    private var path = CGRect.null
    private var resources: [CGPDFDictionaryRef] = []
    private var depth = 0

    init(page: CGPDFPage) {
        if let dict = page.dictionary {
            var res: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dict, "Resources", &res), let res { resources = [res] }
        }
        let stream = CGPDFContentStreamCreateWithPage(page)
        scan(stream)
        CGPDFContentStreamRelease(stream)
    }

    private func scan(_ stream: CGPDFContentStreamRef) {
        let table = Self.table
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
    }

    private func add(_ x: CGFloat, _ y: CGFloat) {
        path = path.union(CGRect(origin: CGPoint(x: x, y: y).applying(ctm), size: .zero))
    }

    private func paint() {
        if !path.isNull { paths.append(path) }
        path = .null
    }

    private func draw(_ name: UnsafePointer<CChar>, in scanner: CGPDFScannerRef) {
        for res in resources.reversed() {
            var xobjects: CGPDFDictionaryRef?, stream: CGPDFStreamRef?, subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetDictionary(res, "XObject", &xobjects), let xobjects,
                  CGPDFDictionaryGetStream(xobjects, name, &stream), let stream,
                  let dict = CGPDFStreamGetDictionary(stream),
                  CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype else { continue }
            switch String(cString: subtype) {
            case "Image":
                let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm)
                var width: CGPDFInteger = 0
                CGPDFDictionaryGetInteger(dict, "Width", &width)
                var format = CGPDFDataFormat.raw
                let digest = CGPDFStreamCopyData(stream, &format).map { SHA256.hash(data: $0 as Data) }
                let content = digest.map { Data($0).prefix(8).reduce(0) { $0 << 8 | Int($1) } } ?? 0
                images.append(Image(rect: rect, scale: rect.width > 0 ? CGFloat(width) / rect.width : 0, content: content))
            case "Form" where depth < 8:
                var formResources: CGPDFDictionaryRef?
                CGPDFDictionaryGetDictionary(dict, "Resources", &formResources)
                var matrix = CGAffineTransform.identity
                var array: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dict, "Matrix", &array), let array {
                    var v = [CGPDFReal](repeating: 0, count: 6)
                    for i in 0..<6 { CGPDFArrayGetNumber(array, i, &v[i]) }
                    matrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                }
                let saved = (ctm, path, resources)
                ctm = matrix.concatenating(ctm)
                path = .null
                if let formResources { resources.append(formResources) }
                depth += 1
                let inner = CGPDFContentStreamCreateWithStream(stream, formResources ?? res, CGPDFScannerGetContentStream(scanner))
                scan(inner)
                CGPDFContentStreamRelease(inner)
                depth -= 1
                (ctm, path, resources) = saved
            default:
                break
            }
            return
        }
    }

    // MARK: Operators

    private static func marks(_ info: UnsafeMutableRawPointer?) -> Marks {
        Unmanaged<Marks>.fromOpaque(info!).takeUnretainedValue()
    }

    private static func pop(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat] {
        var values = [CGFloat](repeating: 0, count: count)
        for i in (0..<count).reversed() {
            var v: CGPDFReal = 0
            CGPDFScannerPopNumber(scanner, &v)
            values[i] = CGFloat(v)
        }
        return values
    }

    nonisolated(unsafe) private static let table: CGPDFOperatorTableRef = {
        let t = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(t, "q") { _, i in let m = marks(i); m.stack.append(m.ctm) }
        CGPDFOperatorTableSetCallback(t, "Q") { _, i in let m = marks(i); if let c = m.stack.popLast() { m.ctm = c } }
        CGPDFOperatorTableSetCallback(t, "cm") { s, i in
            let m = marks(i), v = pop(s, 6)
            m.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(m.ctm)
        }
        for op in ["m", "l"] {
            CGPDFOperatorTableSetCallback(t, op) { s, i in let v = pop(s, 2); marks(i).add(v[0], v[1]) }
        }
        CGPDFOperatorTableSetCallback(t, "c") { s, i in
            let m = marks(i), v = pop(s, 6)
            for k in stride(from: 0, to: 6, by: 2) { m.add(v[k], v[k + 1]) }
        }
        for op in ["v", "y"] {
            CGPDFOperatorTableSetCallback(t, op) { s, i in
                let m = marks(i), v = pop(s, 4)
                m.add(v[0], v[1]); m.add(v[2], v[3])
            }
        }
        CGPDFOperatorTableSetCallback(t, "re") { s, i in
            let m = marks(i), v = pop(s, 4)
            m.add(v[0], v[1]); m.add(v[0] + v[2], v[1] + v[3])
        }
        for op in ["f", "F", "f*", "S", "s", "B", "B*", "b", "b*"] {
            CGPDFOperatorTableSetCallback(t, op) { _, i in marks(i).paint() }
        }
        CGPDFOperatorTableSetCallback(t, "n") { _, i in marks(i).path = .null }
        CGPDFOperatorTableSetCallback(t, "Do") { s, i in
            var name: UnsafePointer<CChar>?
            if CGPDFScannerPopName(s, &name), let name { marks(i).draw(name, in: s) }
        }
        return t
    }()
}
