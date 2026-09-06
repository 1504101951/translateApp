# Selection Translation Context

This context defines the user-facing language for translating text selected in another macOS application.

**Current Platform Scope**: The product currently supports macOS 14 and later only. Android, iOS, and Windows are future platform directions and are not part of the current specification, tickets, or acceptance criteria.

_Avoid_: Current Cross-Platform Release, Four-Platform Delivery

Thread: 20260828-145407-9ef8a8
Topic: selection-translation

## Language

**Live Region Translation Session** (planned, #24): An explicitly started session that continuously recognizes text inside a user-selected screen rectangle and translates changed text through the Default Translation Provider. It persists across source-application switches, supports pause/resume/stop, and ends when capture becomes unavailable. It is separate from a Selection Session because the tracked object is a screen region rather than an application's text selection. It does not record a video file or process audio.

**Screenshot Pin** (planned, #22): An independent, movable image preview that stays above other applications until the user closes it. It is separate from the Translation Overlay and does not end when the source application loses focus.

**Shortcut Only Mode**: A settings and menu switch labelled 仅使用快捷键. Enabled means Automatic Translation Trigger is disabled; the Global Translation Shortcut remains available. It is disabled by default.

**Baidu Provider**: A Translation Provider backed by the official Baidu general translation API, with App ID and secret stored in macOS Keychain.

**Bilingual Pair**: One local source paragraph and its translation displayed in the same row, with translation on the left and source on the right. Hovering a translated paragraph highlights its paired source paragraph. Ordinary providers translate source paragraphs sequentially. Model paragraph mode receives the complete source as numbered paragraphs and returns ordered `{id, translation}` segments; IDs must cover every paragraph exactly once. Source text and separator whitespace come from local input. Paragraphs follow nonempty source lines; character selections and semantic subdivisions within an unbroken paragraph are not alignment boundaries. ID validation does not prove translation accuracy.

**Automatic Translation Trigger**: User-controlled appearance of the translation button after a Selection Gesture. Mouse gestures require readable Accessibility text. Keyboard selection gestures may create a pending-text trigger after source, permission, and text-context checks. Passive detection never injects copy keystrokes. Automatic gestures are ignored while a result is retained. Disabling automatic capture ends only an unexpanded trigger.

**Global Translation Shortcut**: A configurable macOS hotkey that reads the current allowed text selection and starts translation directly. It explicitly replaces a retained result with a new Selection Session in the same nonactivating Translation Overlay. An empty read displays a retained error card instead of silently hiding the overlay.

**Exclusion**: Persistent set of application bundle identifiers from which neither automatic gestures nor the Global Translation Shortcut capture text.

**Selection Session**: An interaction identified by a session ID, beginning with an accepted text selection. Its automatic Translation Trigger State ends when the selection is replaced, confirmed empty, dismissed, or the user leaves the source application. Explicit activation retains the Translation Result State through passive selection and source-application changes. Escape and the close button end it; the Global Translation Shortcut may explicitly replace it. Active translation retains the provider and language direction selected at activation.

**Selection Gesture**: Mouse drag, double-click, triple-click, Select All Gesture, or Shift combined with arrow, Home, End, or Page keys. Mouse gestures require readable selected text; keyboard gestures can enter a pending-text Translation Trigger State. Command or Option may refine Shift selection by line or word.

**Select All Gesture**: Command-A in an allowed text context. It creates a Selection Session with readable text or a pending-text trigger that requires explicit activation before reading.

**Text Selection Context**: A focused control that presents document or field text, such as a text area, text field, web area, or a chat message list. File trees and tables are not a Text Selection Context.

_Avoid_: Any Selected String, File Name Selection

**Selection Limit**: The maximum 50,000 characters accepted for one translation. An oversized selection may show the Translation Trigger State, but activation ends locally with a size-limit message and sends no text to a Translation Provider.

_Avoid_: Unlimited Selection, Silent Rejection

**Application Exclusion**: A persistent user choice that prevents Selection Sessions from beginning in one macOS application. Applications are enabled by default whenever their selected text is readable.

_Avoid_: Global Pause, Editable-Field Exclusion

**Translation Overlay**: A nonactivating draggable interface. The whole trigger button and the result card’s 56-point title area support dragging; the close button and selectable body text are independent interaction regions. It initially appears beside the latest mouse position after text capture, clamped to the visible screen. It preserves its position for the current session; unchanged content size does not reposition the window. Explicit replacement by a new translation reanchors it.

_Avoid_: Floating Window, Popup

**Translation Trigger State**: The collapsed state of the Translation Overlay, presented as one 84×36-point rounded translation button. Clicking starts translation; dragging moves the overlay while preserving the source application's keyboard focus.

_Avoid_: Translation Button

**Translation Result State**: The retained, expanded Translation Overlay showing progress, translation, an error, or the selection limit. It remains visible through source-application switches, outside clicks, selection clearing, new passive selections, and settings changes. Escape or the close button dismisses it. The Global Translation Shortcut can explicitly replace it with a new translation.

_Avoid_: Result Window

**Translation History**: The persistent chronological collection of successfully completed translation results available outside their original Selection Sessions. Cancelled, failed, and incomplete attempts are absent.

_Avoid_: History Page, Translation Cache

**Translation History Window**: The independent application window opened from the menu bar to browse Translation History. It is separate from the Translation Overlay.

_Avoid_: Overlay History, History Panel

**History Recording**: The user-controlled choice to add future Translation Records to Translation History. It is enabled by default; disabling it preserves existing Translation Records while preventing new ones.

_Avoid_: Private Mode, Clear History

**Translation Record**: One entry in Translation History containing the source text, translated text, detected source language, target language, Translation Provider, optional model name, and completion time. Every successful translation creates a new Translation Record, including repeated source text; the record does not identify the source application or selection location.

_Avoid_: Request Log, Activity Record

**Translation Update**: An incremental addition to the translated text shown in the Translation Result State. Every Translation Provider produces one or more Translation Updates before completing, including providers that return the whole result at once.

_Avoid_: Provider Response, Stream Chunk

**Segmented Translation**: One translation of long selected text that processes Translation Segments sequentially in source order but presents them as a single continuous result.

_Avoid_: Batch Translation, Multiple Translations

**Translation Segment**: An ordered portion of a Segmented Translation sent to the Translation Provider as one request. A segment targets 4,000 characters and may overflow to 6,000 characters to preserve a paragraph; only a paragraph longer than 6,000 characters is divided further at sentence boundaries, with a hard character boundary as the last resort.

_Avoid_: Stream Chunk, Split Paragraph

**Sliding Translation Context**: The bounded tail of the immediately preceding Translation Segment supplied to the next model-backed Translation Provider request for semantic continuity. It contains at most 1,000 characters of preceding source text and 1,000 characters of preceding translated text, never accumulates earlier segments, and is ignored by Google-backed Translation Providers.

_Avoid_: Full Translation History, Accumulated Prompt

**Segment Failure**: A Translation Failure affecting one Translation Segment. Completed segments remain visible, retry resumes from the failed segment, and no Translation Record is created until every segment completes successfully.

_Avoid_: Restarted Translation, Partial Translation Record

**Primary Language**: The preferred destination language for selected text written in any language other than the Primary Language. It initially follows the user's first macOS preferred language.

_Avoid_: Fixed Target Language

**Secondary Language**: An optional destination language for text detected as the Primary Language. It is unset by default and can be cleared and saved. When present, it must differ from the Primary Language.

_Avoid_: Fallback Language

**Detected Language**: The source language determined on the device before translation begins. Every Translation Provider receives the same Detected Language for a given Selection Session.

_Avoid_: Provider-Detected Language

**Translation Direction**: With a Secondary Language, text detected as the Primary Language targets the Secondary Language and all other or unknown languages target the Primary Language. Without a Secondary Language, every selection targets the Primary Language. Text already in the target language is returned unchanged with paragraph pairs and no external translation request.

_Avoid_: Manual Source Language

**Translation Provider**: The selected external source that translates text during a Selection Session. Official translation products, unofficial translation endpoints, and language models share the same translation request and result semantics.

_Avoid_: Translation Kernel, Model Engine

**Model Profile**: A named, reusable configuration for one model-backed Translation Provider and its Translation Prompt. Multiple Model Profiles may coexist, and any one of them may be selected as the Default Translation Provider.

_Avoid_: Model Connection, Provider Instance

**Translation Prompt**: The user-editable instruction owned by one Model Profile that tells its model-backed Translation Provider how to produce translated text. It contains no request variables because the selected text and Translation Direction are supplied separately; each Model Profile starts with the same default instruction, and Google-backed Translation Providers do not use a Translation Prompt.

_Avoid_: Google Prompt, Hidden System Prompt

**Default Translation Prompt**: The initial Translation Prompt that requires translation-only output, preserves paragraphs and line breaks, leaves code-like content unchanged, follows the supplied Translation Direction, and uses Sliding Translation Context without repeating it.

_Avoid_: Explanatory Translation, Context Echo

**Default Translation Provider**: The Translation Provider used immediately when the user activates the Translation Trigger State. It is selected outside the current Selection Session, does not require another choice before translation begins, and initially uses the Unofficial Google Provider for zero-configuration translation.

_Avoid_: Per-Selection Provider

**Translation Failure**: The unsuccessful end of a translation attempt by the Default Translation Provider. The selected text is not sent to another Translation Provider automatically.

_Avoid_: Provider Failover

**Official Google Provider**: The Translation Provider backed by Google Cloud Translation and configured with the user's cloud credentials.

**Unofficial Google Provider**: The Translation Provider backed by Google Translate's consumer endpoint, whose availability is not guaranteed.

**OpenAI-Compatible Provider**: A model-backed Translation Provider configured for an OpenAI-compatible endpoint and model. Configurations using the official `api.deepseek.com` host disable thinking through the protocol.

_Avoid_: OpenAI Provider

**Anthropic Provider**: A model-backed Translation Provider configured for Anthropic's native model endpoint.

_Avoid_: OpenAI-Compatible Claude
