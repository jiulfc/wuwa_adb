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
            throw replayError("文字条件需要非空 text 字符串或非空字符串数组，以及有效的归一化区域 [x, y, width, height]。")
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

struct PickupTextCondition: Decodable {
    let text: [String]
    let regions: [[Double]]

    private enum CodingKeys: String, CodingKey { case text, regions }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let single = try? values.decode(String.self, forKey: .text) {
            text = [single]
        } else {
            text = try values.decode([String].self, forKey: .text)
        }
        regions = try values.decode([[Double]].self, forKey: .regions)
    }

    func validate() throws {
        guard !regions.isEmpty else {
            throw replayError("拾取文字条件需要非空 regions 区域数组。")
        }
        for region in regions {
            try TextStopCondition(text: text, region: region).validate()
        }
    }

    func matchingRegion(in frame: URL,
                        onCheck: ([Double], String, Bool) throws -> Void) throws -> [Double]? {
        try validate()
        for region in regions {
            let condition = TextStopCondition(text: text, region: region)
            let recognized = try condition.recognize(in: frame)
            let matched = condition.matches(recognized)
            try onCheck(region, recognized, matched)
            if matched { return region }
        }
        return nil
    }
}
