import AppKit
import CoreGraphics
import CoreVideo
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

/// 系统截图模块的权限与冻结帧；本进程捕获才会把 TranslateApp 写入屏幕录制 TCC。
enum ScreenCaptureService {
    /// 指针所在显示器的冻结帧，包含PNG像素、像素尺寸、AppKit显示坐标及可选前台窗口裁剪框。
    struct FreezeFrame {
        let displayID: CGDirectDisplayID
        let scale: CGFloat
        let png: Data
        let pixelWidth: Int
        let pixelHeight: Int
        /// AppKit 屏幕坐标下的显示器矩形，编辑窗与冻结帧对齐。
        let displayFrame: NSRect
        /// 前台窗口映射到冻结帧像素的裁剪框；找不到则为 nil。
        let windowCrop: NSRect?
    }

    /// 无参数；返回本进程当前是否已获屏幕录制授权。
    static func isAuthorized() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 无参数；已授权则直接复用，不再弹系统框。
    /// 不写 TCC.db；ad-hoc 重签后系统会当成新身份，那时仍需再授权一次。
    /// promoteToRegularApp 为 true 时才切到普通激活，避免截图时 Dock/整屏闪一下。
    @MainActor
    static func requestAccess(promoteToRegularApp: Bool = false) async -> Bool {
        if isAuthorized() { return true }
        let previousPolicy = NSApp.activationPolicy()
        if promoteToRegularApp, previousPolicy != .regular {
            _ = NSApp.setActivationPolicy(.regular)
        }
        if promoteToRegularApp {
            NSApp.activate(ignoringOtherApps: true)
        }
        // 只在尚未授权时申请；已授权不得再次 CGRequest。
        _ = CGRequestScreenCaptureAccess()
        // 只打开设置页不会把本进程写入列表；ScreenCaptureKit 枚举才会登记 TranslateApp。
        _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        for _ in 0..<20 {
            if isAuthorized() {
                restoreActivationPolicy(previousPolicy)
                return true
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        restoreActivationPolicy(previousPolicy)
        return isAuthorized()
    }

    /// previous 为申请前的激活策略；申请结束后恢复菜单栏形态。
    @MainActor
    private static func restoreActivationPolicy(_ previous: NSApplication.ActivationPolicy) {
        if NSApp.activationPolicy() != previous {
            _ = NSApp.setActivationPolicy(previous)
        }
    }

    /// 无参数；打开系统「屏幕录制」设置页，不修改 TCC 数据库。
    static func openScreenRecordingSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    /// displayID明确目标屏，空值使用指针所在屏；showsCursor 为冻结帧是否包含鼠标指针。
    /// 返回冻结帧，目标消失时抛错，不切换到其他屏幕。
    static func captureActiveDisplay(displayID: CGDirectDisplayID?, showsCursor: Bool) async throws -> FreezeFrame {
        let mouse = NSEvent.mouseLocation
        let screen = displayID == nil
            ? (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)
            : NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }
        guard let screen else {
            throw NSError(
                domain: "TranslateApp",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "找不到可用显示器。"]
            )
        }
        let screenNumber = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
        guard let screenNumber else {
            throw NSError(
                domain: "TranslateApp",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "无法读取显示器内容，请检查屏幕录制权限。"]
            )
        }
        let (image, scale) = try await captureDisplayImage(displayID: screenNumber, showsCursor: showsCursor)
        let png = try pngData(from: image, scale: scale)
        return FreezeFrame(
            displayID: screenNumber,
            scale: scale,
            png: png,
            pixelWidth: image.width,
            pixelHeight: image.height,
            displayFrame: screen.frame,
            windowCrop: CaptureGeometry.frontmostWindowPixelCrop(
                displayFrame: screen.frame,
                pixelWidth: image.width,
                pixelHeight: image.height
            )
        )
    }

    /// displayID 为目标显示器，showsCursor 为是否绘制鼠标指针（区域截图按设置，MCP 不绘制）。
    /// 返回该显示器物理像素的图像与点到像素比例；显示器不在可捕获列表时抛错。
    static func captureDisplayImage(displayID: CGDirectDisplayID, showsCursor: Bool) async throws -> (image: CGImage, scale: CGFloat) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(
                domain: "TranslateApp",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "无法读取显示器内容，请检查屏幕录制权限。"]
            )
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        // contentRect 是点，必须乘 pointPixelScale 才是物理像素；用 1x 缓冲再拉伸会整屏发糊。
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = imageConfiguration(
            width: max(display.width, Int((filter.contentRect.width * scale).rounded())),
            height: max(display.height, Int((filter.contentRect.height * scale).rounded())),
            showsCursor: showsCursor
        )
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return (image, scale)
    }

    /// 无参数。返回屏上可见的普通层级窗口，排除本进程窗口；坐标为全局点坐标（原点主显示器左上角）。
    static func visibleWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter {
            $0.isOnScreen && $0.windowLayer == 0 && $0.owningApplication?.processID != ownPID
                && $0.frame.width > 0 && $0.frame.height > 0
        }
    }

    /// window 为可见窗口。返回只含该窗口自身内容的物理像素图像，窗口被遮挡时仍截取窗口内容。
    static func captureWindowImage(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = imageConfiguration(
            width: max(1, Int((filter.contentRect.width * scale).rounded())),
            height: max(1, Int((filter.contentRect.height * scale).rounded())),
            showsCursor: false
        )
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// width、height 为输出物理像素，showsCursor 为是否绘制鼠标指针。返回不含音频、按 sRGB 原尺寸输出的静态截图配置。
    private static func imageConfiguration(width: Int, height: Int, showsCursor: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = showsCursor
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        // 按物理像素尺寸输出，禁止系统缩放捕获内容。
        configuration.scalesToFit = false
        return configuration
    }

    /// png 为截图像素；返回 OCR Markdown（块之间空一行），无字返回空字符串。截图编辑「识别文字」与 MCP 共用（#96）。
    static func recognizeText(png: Data) async throws -> String {
        guard let image = NSBitmapImageRep(data: png)?.cgImage else {
            throw NSError(
                domain: "TranslateApp",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "无法读取截图以识别文字。"]
            )
        }
        return try await recognizeDocument(image: image).map(\.markdown).joined(separator: "\n\n")
    }

    /// OCR Markdown 的一个块；rect 为块在识别图像中的像素框，原点左上。
    struct OCRBlock: Equatable {
        let markdown: String
        let rect: CGRect
    }

    /// Vision 文档结构的中间表示；像素框原点左上。与 Vision 类型解耦，Markdown 组织规则可单独验证。
    struct OCRLayout {
        /// 表格单元格；row、column 为合并区域的起始行列。
        struct Cell {
            let row: Int
            let column: Int
            let text: String
        }

        var title: (text: String, rect: CGRect)?
        var paragraphs: [(text: String, rect: CGRect)] = []
        var lists: [(items: [String], rect: CGRect)] = []
        var tables: [(cells: [Cell], rect: CGRect)] = []
    }

    /// image 为截图像素。用 Vision 文档识别得到标题、段落、列表与表格，返回按阅读顺序排列的 Markdown 块。
    static func recognizeDocument(image: CGImage) async throws -> [OCRBlock] {
        let observations = try await paragraphRequest().perform(on: image)
        let width = Double(image.width)
        let height = Double(image.height)
        // 识别框为归一化坐标、原点在左下，换成像素并翻到左上原点。
        let pixels = { (region: NormalizedRegion) -> CGRect in
            let box = region.boundingBox.cgRect
            return CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width, height: box.height * height)
        }
        return observations.flatMap { observation -> [OCRBlock] in
            let document = observation.document
            var layout = OCRLayout()
            layout.title = document.title.map { ($0.transcript, pixels($0.boundingRegion)) }
            layout.paragraphs = document.paragraphs.map { ($0.transcript, pixels($0.boundingRegion)) }
            layout.lists = document.lists.map { list in (list.items.map(\.itemString), pixels(list.boundingRegion)) }
            layout.tables = document.tables.map { table in
                let cells = table.rows.flatMap { $0 }.map {
                    OCRLayout.Cell(row: $0.rowRange.lowerBound, column: $0.columnRange.lowerBound, text: $0.content.text.transcript)
                }
                return (cells, pixels(table.boundingRegion))
            }
            return markdownBlocks(layout)
        }
    }

    /// layout 为一页文档结构。返回 Markdown 块（#96「工具」返回 4）：标题为 `# 标题`，段落为纯文本，列表每项一行 `- 项`，
    /// 表格为首行作表头的 Markdown 表格；已在表格或列表内的段落与重复标题不再输出；按块顶部、再按左边缘排序。
    static func markdownBlocks(_ layout: OCRLayout) -> [OCRBlock] {
        var blocks: [OCRBlock] = []
        let title = layout.title.map { (text: normalized($0.text), rect: $0.rect) }
        if let title, !title.text.isEmpty {
            blocks.append(OCRBlock(markdown: "# \(title.text.replacingOccurrences(of: "\n", with: " "))", rect: title.rect))
        }
        let covered = layout.lists.map(\.rect) + layout.tables.map(\.rect)
        for paragraph in layout.paragraphs {
            let text = normalized(paragraph.text)
            let center = CGPoint(x: paragraph.rect.midX, y: paragraph.rect.midY)
            // 段落中心落在表格或列表内，说明该文字已由表格或列表输出。
            guard !text.isEmpty, text != title?.text, !covered.contains(where: { $0.contains(center) }) else { continue }
            blocks.append(OCRBlock(markdown: text, rect: paragraph.rect))
        }
        for list in layout.lists {
            let items = list.items.map { cellText($0, escapePipes: false) }.filter { !$0.isEmpty }
            guard !items.isEmpty else { continue }
            blocks.append(OCRBlock(markdown: items.map { "- \($0)" }.joined(separator: "\n"), rect: list.rect))
        }
        for table in layout.tables {
            guard let markdown = tableMarkdown(table.cells) else { continue }
            blocks.append(OCRBlock(markdown: markdown, rect: table.rect))
        }
        return blocks.sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
    }

    /// cells 为表格单元格。返回首行作表头的 Markdown 表格；合并单元格只写在起始格，同一起始格只取第一次出现；无单元格时为 nil。
    private static func tableMarkdown(_ cells: [OCRLayout.Cell]) -> String? {
        guard let rows = cells.map(\.row).max().map({ $0 + 1 }),
              let columns = cells.map(\.column).max().map({ $0 + 1 }) else { return nil }
        var grid = Array(repeating: Array(repeating: Optional<String>.none, count: columns), count: rows)
        for cell in cells where grid[cell.row][cell.column] == nil {
            grid[cell.row][cell.column] = cellText(cell.text, escapePipes: true)
        }
        let lines = grid.map { row in "| " + row.map { $0 ?? "" }.joined(separator: " | ") + " |" }
        let separator = "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"
        return ([lines[0], separator] + lines.dropFirst()).joined(separator: "\n")
    }

    /// text 为段落原文。返回合并连续空格、去掉每行首尾空白与空行后的文字。
    private static func normalized(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// text 为表格单元格或列表项原文；escapePipes 为 true 时转义 `|`。返回单行文字，所有空白合并为一个空格。
    private static func cellText(_ text: String, escapePipes: Bool) -> String {
        let single = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return escapePipes ? single.replacingOccurrences(of: "|", with: "\\|") : single
    }

    /// pixelBuffer 为屏幕流帧。返回段落块：text 为整段原文，x/y/width/height 为段落外接矩形的像素框，坐标原点在图像左上。
    static func recognizeParagraphs(pixelBuffer: CVPixelBuffer) async throws -> [[String: Any]] {
        let observations = try await paragraphRequest().perform(on: pixelBuffer)
        return paragraphBlocks(
            observations.flatMap { $0.document.paragraphs },
            width: Double(CVPixelBufferGetWidth(pixelBuffer)),
            height: Double(CVPixelBufferGetHeight(pixelBuffer))
        )
    }

    /// 无参数；返回中英文段落识别请求，屏幕流帧与静态截图共用同一识别配置。
    private static func paragraphRequest() -> RecognizeDocumentsRequest {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.useLanguageCorrection = true
        request.textRecognitionOptions.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].map {
            Locale.Language(identifier: $0)
        }
        return request
    }

    /// paragraphs 为识别出的段落，width/height 为图像像素。返回左上原点的段落像素框，跳过空段落。
    private static func paragraphBlocks(
        _ paragraphs: [DocumentObservation.Container.Text],
        width: Double,
        height: Double
    ) -> [[String: Any]] {
        // 段落识别把折行文字合成一段；列表项与表格单元格各自成段。
        paragraphs.compactMap { paragraph in
            let text = paragraph.transcript
            guard !text.isEmpty else { return nil }
            // 识别框为归一化坐标、原点在左下，换成像素并翻到左上原点。
            let box = paragraph.boundingRegion.boundingBox.cgRect
            return [
                "text": text,
                "x": box.minX * width,
                "y": (1 - box.maxY) * height,
                "width": box.width * width,
                "height": box.height * height,
            ]
        }
    }

    /// png 为截图像素；返回带像素框的 OCR 块，坐标原点在左上。
    static func recognizeBlocks(png: Data) throws -> [[String: Any]] {
        guard let image = NSBitmapImageRep(data: png)?.cgImage else {
            throw NSError(
                domain: "TranslateApp",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "无法读取截图以识别文字。"]
            )
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return blocks(from: request, width: Double(image.width), height: Double(image.height))
    }

    /// request 为已执行的识别，width/height 为图像像素。返回左上原点的文字块。
    private static func blocks(from request: VNRecognizeTextRequest, width: Double, height: Double) -> [[String: Any]] {
        (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else {
                return nil
            }
            let box = observation.boundingBox
            return [
                "text": text,
                "x": box.minX * width,
                "y": (1 - box.maxY) * height,
                "width": box.width * width,
                "height": box.height * height,
            ]
        }
    }

    /// image 为冻结帧，scale 为点到物理像素比；按像素编码 PNG，并写入 DPI 以免贴图按 72DPI 放大发糊。
    static func pngData(from image: CGImage, scale: CGFloat) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw NSError(
                domain: "TranslateApp",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "无法编码冻结帧。"]
            )
        }
        let dpi = 72.0 * Double(max(scale, 1))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(
                domain: "TranslateApp",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "无法编码冻结帧。"]
            )
        }
        return data as Data
    }
}
