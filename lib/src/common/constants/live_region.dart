/// 实时翻译会话阶段；name 为跨引擎协议值，与 Swift LiveRegionPhase 逐项一致（#127）。
enum LiveRegionPhase { idle, running, paused, ended, discarded }

/// 原生协调器发给主引擎的实时翻译命令；name 为协议值，与 Swift LiveRegionAction 逐项一致（#127）。
enum LiveRegionAction { start, pause, resume, end, discard, captureFailed }
