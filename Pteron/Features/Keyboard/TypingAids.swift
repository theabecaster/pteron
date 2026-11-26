import Foundation
import RexKit
import UIKit

/// What the system keyboard may do to the text typed into a pane: autocorrection and spell
/// checking while an agent is the program in front, where people type prose to it, and nothing
/// anywhere else. A shell, an editor, a pager or `ssh` takes what is typed as is: a corrected
/// `ls` would be a different command.
///
/// Off in an agent too, measured in a simulator against the keyboard of iOS 27.2:
/// - Capitals at the start of a sentence. The shadow document is empty after every Return, so the
///   keyboard puts its shift on for the first letter of every line: `y` at a question became
///   `Y`, `ls` became `Ls` and then `Last`, and `j` in an agent's vim mode would be `J`.
///   Autocorrection still capitalizes `i` and names.
/// - Smart quotes, smart dashes, smart insert and delete: a prompt holds code and paths.
/// - Inline predictions: grey text after the cursor, which a terminal has no place to draw.
struct TypingAids: Equatable {
    var autocorrection: UITextAutocorrectionType
    var spellChecking: UITextSpellCheckingType

    /// A terminal's keyboard: what is typed is sent as is.
    static let raw = TypingAids(autocorrection: .no, spellChecking: .no)
    /// An agent's prompt. Either aid brings the keyboard's suggestion bar, which shows a
    /// correction before it is made and offers the typed word back.
    static let prose = TypingAids(autocorrection: .yes, spellChecking: .yes)

    var corrects: Bool { autocorrection == .yes }

    /// The aids for a pane with this metadata.
    static func `for`(_ meta: BlockMeta?) -> TypingAids {
        agentInFront(foreground: meta?.foreground, statusApp: meta?.topStatus?.app) ? .prose : .raw
    }

    /// True only when an agent is the program the keys go to.
    ///
    /// - The foreground program is an agent (`AgentKind.fromProgram`): yes. A shell command the
    ///   agent runs (`!ls` in Claude Code) runs under it, so the agent is still in front.
    /// - A shell is in front: no, whatever an agent reported before. An agent that exited or was
    ///   suspended can leave its status record and its title behind.
    /// - Anything else (`ssh`, `mosh`, a program the server names by its version, an unknown
    ///   foreground): only an agent's own OSC 7501 record says yes. A title never does: an
    ///   agent's title outlives it in a program that sets none (a `vim` started after `claude`
    ///   exits), and over `ssh` in a remote shell that sets none.
    static func agentInFront(foreground: String?, statusApp: String?) -> Bool {
        if let foreground, AgentKind.fromProgram(foreground) != nil { return true }
        if let name = EchoForeground.normalize(foreground), ProcessNames.isShell(name) { return false }
        return statusApp.flatMap(AgentKind.fromApp) != nil
    }

    /// Characters that make a word part of a path, a file name, a flag, a mention or a variable
    /// when they touch it.
    static let codeMarks: Set<Character> = ["/", "\\", ".", "@", "-", "_", "~", ":", "=", "$", "#", "`", "*", "<", ">", "|"]

    /// True when the keyboard's correction of `range` in `line` (the shadow document) must not be
    /// made: the word touches a code mark (`src/compnent.tsx`, whose `tsx` the keyboard makes
    /// `tax`; `-la`; `@file`), holds anything but letters and apostrophes, or the line is a shell
    /// command for the agent to run (`!ls src`, whose `src` it makes `sec`). A plain word in
    /// prose (`teh`, `i`) is corrected, and so is a double space (the keyboard's period shortcut).
    static func keepsTyped(_ line: String, replacing range: NSRange) -> Bool {
        let s = line as NSString
        guard range.location >= 0, NSMaxRange(range) <= s.length else { return true }
        if line.drop(while: { $0 == " " }).first == "!" { return true }
        let word = s.substring(with: range)
        // The keyboard's period shortcut: a double space becomes ". ".
        if !word.isEmpty, word.allSatisfy(\.isWhitespace) { return false }
        if word.contains(where: { !$0.isLetter && $0 != "'" && $0 != "’" }) { return true }
        if range.location > 0, let before = s.substring(with: NSRange(location: range.location - 1, length: 1)).first,
           codeMarks.contains(before) { return true }
        if NSMaxRange(range) < s.length, let after = s.substring(with: NSRange(location: NSMaxRange(range), length: 1)).first,
           codeMarks.contains(after) { return true }
        return false
    }
}

/// Tells the panes that show a block when the aids its program asks for change. One per computer
/// (`ServerConnection.typingAids`), fed by its metadata table: the rule runs only when the
/// program in front or the agent's record changes, never per key or per frame.
@MainActor
final class TypingAidsWatch {
    private var observers: [String: [@MainActor (TypingAids) -> Bool]] = [:]

    /// Calls `body` with each new value of this block's aids, until it returns false.
    func observe(block: String, _ body: @escaping @MainActor (TypingAids) -> Bool) {
        observers[block, default: []].append(body)
    }

    /// A block's metadata changed.
    func metaChanged(_ block: String, from old: BlockMeta?, to new: BlockMeta?) {
        guard let current = observers[block],
              old?.foreground != new?.foreground || old?.topStatus?.app != new?.topStatus?.app else { return }
        let aids = TypingAids.for(new)
        guard aids != TypingAids.for(old) else { return }
        observers[block] = []
        let kept = current.filter { $0(aids) } + (observers[block] ?? [])
        observers[block] = kept.isEmpty ? nil : kept
    }

    /// The block closed: nobody hears of it again.
    func forget(block: String) { observers[block] = nil }

    /// How many observers the block has. For tests.
    func count(block: String) -> Int { observers[block]?.count ?? 0 }
}
