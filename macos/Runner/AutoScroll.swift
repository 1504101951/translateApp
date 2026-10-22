import AppKit
import ApplicationServices

/// 长截图自动滚动的步进状态机（#112）：每次滚动后等画面开始移动并停稳再滚下一步，按实测位移校准滚动条增量。
/// 纯逻辑：输入每帧追加的正文像素与接缝失败，时间由调用方传入；输出下一步动作，不读写屏幕或其他应用。
struct AutoScrollPlan {
    /// 采集循环据此执行的动作。
    enum Action: Equatable {
        /// 继续采样，不滚动。
        case wait
        /// 滚动条值增加该增量（0–1 范围内的比例）。
        case scroll(by: Double)
        /// 本步跨出可配准范围：退回本步之前的位置。
        case rewind
        /// 曾经滚动过且本步无移动：已到底部，自动暂停。
        case bottom
        /// 首步无移动：来源不响应滚动条，改为手动。
        case unsupported
    }

    /// 停稳判定：画面移动后连续静止的采样数（采样间隔 100ms，即 200ms）。
    static let settledFrames = 2
    /// 单步最长等待；画面仍在移动也开始下一步。
    static let maximumWait: Duration = .milliseconds(1000)
    /// 滚动后无移动的到底判定时长。
    static let bottomWait: Duration = .milliseconds(1500)
    /// 首步滚动条增量；之后按实测位移校准。
    static let initialStep = 0.01

    /// 单步目标位移（像素）：选区高度的 50%。
    let target: Int
    /// 下一步的滚动条增量。
    private(set) var step = initialStep
    /// 最近一次滚动或退回的时刻；到底或不支持后为 nil，直到再次 start。
    private var stepped: ContinuousClock.Instant?
    /// 本步以来累计追加的正文像素与连续静止帧数。
    private var moved = 0
    private var still = 0
    /// 正在等待退回后的画面停稳。
    private var rewinding = false
    /// 本次会话是否有任何一步产生过移动；区分到底与不支持。
    private var everMoved = false

    /// height为选区像素高度；单步目标取其一半。
    init(height: Int) { target = max(1, height / 2) }

    /// now为开始时刻；开始（或暂停后恢复）一轮自动滚动，返回第一步滚动。
    mutating func start(now: ContinuousClock.Instant) -> Action {
        rewinding = false
        begin(now)
        return .scroll(by: step)
    }

    /// shift为本帧追加的正文像素（静止为 0），now为采样时刻；返回下一步动作。
    mutating func frame(shift: Int, now: ContinuousClock.Instant) -> Action {
        guard let stepped else { return .wait }
        if shift > 0 {
            moved += shift
            still = 0
        } else {
            still += 1
        }
        if rewinding {
            // 退回后画面回到参照帧，停稳即按减半的步长重试。
            guard still >= Self.settledFrames else { return .wait }
            rewinding = false
            begin(now)
            return .scroll(by: step)
        }
        if moved > 0, still >= Self.settledFrames || now - stepped >= Self.maximumWait {
            everMoved = true
            // 按本步「增量/位移」比例换算到目标位移；最多放大到 4 倍，避免一次跨出可配准范围。
            step = min(step * 4, step * Double(target) / Double(moved))
            begin(now)
            return .scroll(by: step)
        }
        guard moved == 0, now - stepped >= Self.bottomWait else { return .wait }
        self.stepped = nil
        return everMoved ? .bottom : .unsupported
    }

    /// now为接缝失败时刻；步长减半并返回退回，画面停稳后再重试。
    mutating func mismatch(now: ContinuousClock.Instant) -> Action {
        step /= 2
        rewinding = true
        begin(now)
        return .rewind
    }

    /// now为本步开始时刻；清零本步的移动与静止计数，无返回值。
    private mutating func begin(_ now: ContinuousClock.Instant) {
        stepped = now
        moved = 0
        still = 0
    }
}

/// 自动滚动目标（#112）：选区中心处来源窗口的纵向滚动条。只经辅助功能接口读写滚动条值，
/// 不发送滚轮事件、不移动指针；调用方须已确认辅助功能权限。
final class AutoScrollTarget {
    private let bar: AXUIElement

    /// point为 CG 全局坐标（左上原点）；返回该点最上层、非本应用普通窗口内可设置值的纵向滚动条，找不到时返回 nil。
    init?(point: CGPoint) {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let own = ProcessInfo.processInfo.processIdentifier
        // 窗口列表按前后顺序排列；第 0 层是普通应用窗口，采集遮罩等本应用窗口不参与。
        let owner = windows.first { info in
            guard info[kCGWindowLayer as String] as? Int == 0, info[kCGWindowOwnerPID as String] as? pid_t != own,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return rect.contains(point)
        }
        guard let pid = owner?[kCGWindowOwnerPID as String] as? pid_t else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid), Float(point.x), Float(point.y), &hit) == .success,
              var current = hit else { return nil }
        // 从命中元素向上找最近的滚动区；网页与列表都嵌在滚动区内，层级不超过 30。
        for _ in 0..<30 {
            if Self.attribute(current, kAXRoleAttribute) as? String == kAXScrollAreaRole as String,
               let found = Self.attribute(current, kAXVerticalScrollBarAttribute) {
                let bar = found as! AXUIElement
                var settable = DarwinBoolean(false)
                guard AXUIElementIsAttributeSettable(bar, kAXValueAttribute as CFString, &settable) == .success,
                      settable.boolValue else { return nil }
                self.bar = bar
                return
            }
            guard let parent = Self.attribute(current, kAXParentAttribute) else { return nil }
            current = parent as! AXUIElement
        }
        return nil
    }

    /// 无参数；返回当前滚动条值（0 顶部、1 底部），读取失败返回 nil。
    var value: Double? { (Self.attribute(bar, kAXValueAttribute) as? NSNumber)?.doubleValue }

    /// value为目标值，截到 0–1；写入滚动条，返回是否成功。
    @discardableResult
    func set(_ value: Double) -> Bool {
        AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: min(1, max(0, value)))) == .success
    }

    /// element为辅助功能元素，name为属性名；返回属性值，读取失败返回 nil。
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
