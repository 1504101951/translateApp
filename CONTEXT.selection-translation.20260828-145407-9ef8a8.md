# Selection Translation Context

This context defines the user-facing language for translating text selected in another macOS application.

Thread: 20260828-145407-9ef8a8
Topic: selection-translation

## Language

**Selection Session**: The temporary interaction that begins when the user completes a new text selection and ends when that selection is replaced or dismissed.

**Selection Gesture**: A mouse drag, double-click, or triple-click that selects text and begins a Selection Session. Keyboard-created selections do not begin a Selection Session.

_Avoid_: Keyboard Selection

**Selection Limit**: The maximum 50,000 characters accepted for one translation. An oversized selection may show the Translation Trigger State, but activation ends locally with a size-limit message and sends no text to a Translation Provider.

_Avoid_: Unlimited Selection, Silent Rejection

**Application Exclusion**: A persistent user choice that prevents Selection Sessions from beginning in one macOS application. Applications are enabled by default whenever their selected text is readable.

_Avoid_: Global Pause, Editable-Field Exclusion

**Translation Overlay**: The draggable interface anchored beside the current selection. It retains its dragged position throughout the current Selection Session and returns beside the new selection when another Selection Session begins.

_Avoid_: Floating Window, Popup

**Translation Trigger State**: The collapsed state of the Translation Overlay that offers the translation action without starting translation.

_Avoid_: Translation Button

**Translation Result State**: The expanded state of the Translation Overlay that presents translation progress and the resulting text. It remains available while the user works elsewhere and ends only when dismissed, when the user presses Escape, or when a new Selection Session begins.

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

**Secondary Language**: The destination language used when the selected text is detected as the Primary Language. It initially uses English, or Simplified Chinese when the Primary Language is English.

_Avoid_: Fallback Language

**Detected Language**: The source language determined on the device before translation begins. Every Translation Provider receives the same Detected Language for a given Selection Session.

_Avoid_: Provider-Detected Language

**Translation Direction**: The automatically selected direction between the Primary Language and Secondary Language. Primary Language text is translated into the Secondary Language; all other text, including text without a reliable Detected Language, is translated into the Primary Language.

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

**OpenAI-Compatible Provider**: A model-backed Translation Provider configured for an OpenAI-compatible endpoint and model.

_Avoid_: OpenAI Provider

**Anthropic Provider**: A model-backed Translation Provider configured for Anthropic's native model endpoint.

_Avoid_: OpenAI-Compatible Claude
