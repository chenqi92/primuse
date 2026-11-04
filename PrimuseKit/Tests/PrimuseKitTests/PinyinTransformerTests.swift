import Foundation
import Testing
@testable import PrimuseKit

struct PinyinTransformerTests {
    @Test func repeatedAndConcurrentTransformsPreserveResults() async {
        let inputs = ["周杰伦", "Beyond 海阔天空", "Café", "あいう", "  周杰伦  ", "", "ABC 123"]
        func reference(_ input: String) -> String? {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = NSMutableString(string: trimmed)
            guard CFStringTransform(value, nil, kCFStringTransformMandarinLatin, false) else { return nil }
            CFStringTransform(value, nil, kCFStringTransformStripCombiningMarks, false)
            let result = (value as String).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return result.isEmpty || result == trimmed.lowercased() ? nil : result
        }
        let expected = inputs.map(reference)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    for (offset, input) in inputs.enumerated() {
                        #expect(PinyinTransformer.pinyin(input) == expected[offset])
                    }
                }
            }
        }
        #expect(PinyinTransformer.initials("周杰伦") == "zjl")
    }
}
