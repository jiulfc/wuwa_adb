import Foundation
import Vision

struct TextStopCondition: Decodable {
    let text: [String]
    let region: [Double]

    init(text: String, region: [Double]) {
        self.init(text: [text], region: region)
    }

    init(text: [String], region: [Double]) {
        self.text = text
        self.region = region
    }

    private enum CodingKeys: String, CodingKey { case text, region }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let single = try? values.decode(String.self, forKey: .text) {
            text = [single]
        } else {
            text = try values.decode([String].self, forKey: .text)
        }
        region = try values.decode([Double].self, forKey: .region)
    }

    func validate() throws {
        guard !text.isEmpty, text.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              region.count == 4, region.allSatisfy({ $0.isFinite }),
              region[0] >= 0, region[1] >= 0, region[2] > 0, region[3] > 0,
              region[0] + region[2] <= 1, region[1] + region[3] <= 1 else {
            throw replayError("Text conditions need a non-empty text string or non-empty string array, plus a valid normalized region [x, y, width, height].")
        }
    }

    func matches(_ recognized: String) -> Bool {
        let actual = recognized.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
        return text.contains { phrase in
            let expected = phrase.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
            return !expected.isEmpty && actual.contains(expected)
        }
    }

    func recognize(in frame: URL) throws -> String {
        try validate()
        let request = VNRecognizeTextRequest()
        // Vision's fast mode does not support Chinese.
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        // Vision's origin is bottom-left; script regions use top-left.
        request.regionOfInterest = CGRect(x: region[0], y: 1 - region[1] - region[3],
                                        width: region[2], height: region[3])
        try VNImageRequestHandler(url: frame, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}
