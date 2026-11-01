import AppKit
import CoreAudio
import CoreGraphics
import FluidAudio
import SliveObjC
import SliveReport

@MainActor
enum VocabularyCorrectorTests {
    static let suite = TestSuite(name: "Vocabulary corrector") { t in
        print("[Vocabulary corrector]")
        // Soumil's real list (stored lowercase) plus z-docs.
        let vocab = "claude, complianceos, cos, ios, onfinance, cos-ai-agent, argo cd, compaction, cos-mp-agent, curl, z-docs"
        func fix(_ s: String, _ v: String = vocab) -> String { VocabularyCorrector.correct(s, hotwords: v) }

        // Every way Whisper has spelled z-docs lands on the user's spelling.
        for heard in ["Z docs", "ZDocs", "z docs", "Zdocs", "Z-docs", "Z-Docs", "Z.docs"] {
            t.equal(fix("check the \(heard) folder"), "check the z-docs folder", "\(heard) → z-docs")
        }
        t.equal(fix("we work at on finance today"), "we work at onfinance today", "on finance → onfinance")
        t.equal(fix("on-finance and On Finance"), "onfinance and onfinance", "on-finance / On Finance → onfinance")
        t.equal(fix("the compliance OS team"), "the complianceos team", "compliance OS → complianceos")
        t.equal(fix("ask the CosAI Agent"), "ask the cos-ai-agent", "CosAI Agent → cos-ai-agent")
        t.equal(fix("ask the cos AI agent"), "ask the cos-ai-agent", "cos AI agent → cos-ai-agent")
        t.equal(fix("the CosMP agent runs"), "the cos-mp-agent runs", "CosMP agent → cos-mp-agent")
        t.equal(fix("the POSMP agent runs"), "the cos-mp-agent runs", "one-letter slip in a long term")
        t.equal(fix("two CosMP agents"), "two cos-mp-agents", "plural of a long term kept")
        t.equal(fix("deploy with argocd now"), "deploy with argo cd now", "argocd → argo cd")

        // Punctuation around the match survives byte-for-byte.
        t.equal(fix("Open Z docs."), "Open z-docs.", "trailing period kept")
        t.equal(fix("(ZDocs), then"), "(z-docs), then", "brackets and comma kept")
        t.equal(fix("\"on finance\"?"), "\"onfinance\"?", "quotes and question mark kept")
        t.equal(fix("Z docs is the folder"), "z-docs is the folder",
              "sentence start keeps the user's lowercase form")
        // Several terms in one sentence.
        t.equal(fix("Push Z docs to argocd for the CosMP agent at on finance."),
              "Push z-docs to argo cd for the cos-mp-agent at onfinance.", "multiple terms in one sentence")

        // Guards: short terms and ordinary words never get pulled in.
        let ordinary = "Cause I saw it with my own eyes, she curls up and it costs a lot."
        t.equal(fix(ordinary), ordinary, "ordinary text untouched (cause, eyes, curls, costs)")
        t.equal(fix("cause"), "cause", "cause never becomes cos")
        t.equal(fix("curls"), "curls", "curls untouched")
        t.equal(fix("eyes"), "eyes", "eyes untouched")
        t.equal(fix("we work in finance"), "we work in finance", "a slip in a short word is a different word")
        t.equal(fix("of finance"), "of finance", "of finance untouched")
        t.equal(fix("compliances"), "compliances", "an inserted letter is not a slip")
        t.equal(fix("Z, docs"), "Z, docs", "punctuation between words breaks a match")
        t.equal(fix("Z — docs"), "Z — docs", "bare punctuation between words breaks a match")
        t.equal(fix("I/O's"), "I/O's", "symbols inside a word never match a short term")
        // A plain term's "+s" is another word; only identifiers pluralise.
        t.equal(fix("focus on finances"), "focus on finances", "on finances never becomes onfinances")
        t.equal(fix("two cos AI agents"), "two cos-ai-agents", "identifier plural still applied")
        // The one-letter slip needs a multi-word span: one real word stays.
        t.equal(fix("the internal docs", "interval"), "the internal docs",
              "a single real word a letter off a term is untouched")
        t.equal(fix("the inter val docs", "interval"), "the interval docs", "a split term still matches exactly")
        // A plain lowercase term never lowercases what the model capitalised.
        t.equal(fix("Claude on iOS via Argo CD and COS"), "Claude on iOS via Argo CD and COS",
              "case-only differences of plain lowercase terms left alone")
        // ...but a term typed with capitals is an exact spelling.
        t.equal(fix("ship it on ios", "iOS"), "ship it on iOS", "user casing applied when given")
        t.equal(fix("ship it on IOS", "iOS"), "ship it on iOS", "user casing applied to case-only miss")
        t.equal(fix("open the compliance OS app", "ComplianceOS"), "open the ComplianceOS app",
              "capitalised user form used verbatim")

        // Already correct → no double rewrite; the pass is idempotent.
        let correct = "z-docs, cos-ai-agent, onfinance and argo cd."
        t.equal(fix(correct), correct, "already-correct terms untouched")
        let once = fix("Z docs and CosMP agent on finance")
        t.equal(fix(once), once, "correcting twice changes nothing")

        // Empty vocabulary is the identity.
        t.equal(fix("Z docs on finance", ""), "Z docs on finance", "empty vocabulary → identity")
        t.equal(fix("Z docs on finance", " ,\n "), "Z docs on finance", "whitespace vocabulary → identity")
        t.equal(fix("", vocab), "", "empty text stays empty")
        // Parsing: commas and/or newlines, trimmed, de-duplicated.
        t.equal(VocabularyCorrector.terms(from: " z-docs,\nZ Docs ,\n\nargo  cd ").map(\.form),
              ["z-docs", "argo cd"], "terms parsed, trimmed and de-duplicated")
    }
}
