import Foundation

/// LLM 講者歸屬：低頻背景 pass，把近期輪替（講者代號 + 內容）餵 gpt-5.4-mini
/// （structured output），推每個代號的角色（主持人/來賓/旁白）與可能人名（從互相稱呼），
/// 寫回 SpeakerTimeline 的顯示名 — 之後的 block 從「講者 A」進化成「小明」「旁白」。
/// DiarizationLM（arXiv:2401.03506）的輕量版：只做 forward-only 命名，不回改已歸檔文字。
/// 防幻覺：人名必須是逐字稿裡實際出現過的字串，且 confidence ≥ 0.7 才採用。
@MainActor
final class AttributionEnricher {
    private let store: TranscriptStore
    private let timeline: SpeakerTimeline
    private let apiKey: String?
    private let model = "gpt-5.4-mini"
    private let interval: TimeInterval = 60          // 還有未命名講者時的節奏
    private let steadyInterval: TimeInterval = 600   // 全員已命名後降速 — 省 LLM 也少給 variance 翻盤機會
    private var lastVersion = 0
    private var lastRun = Date.distantPast
    private var running = false
    private var pollTask: Task<Void, Never>?

    /// 聲紋註冊入口（main.swift 接 SpeakerDiarizerPump）— 推出真名後把該講者聲音 enroll，
    /// 之後跨內容/跨啟動由 diarizer 直接認人，不再經 LLM。
    var pumpProvider: (() -> SpeakerDiarizerPump?)?
    /// 上一輪的 letter→name 提案 — enroll 的一致性閘用。
    private var lastNameProposals: [String: String] = [:]
    /// 提案對應的匿名世代 — enroll（含 /name）會重排字母，跨世代的「講者 A」是
    /// 不同人，舊提案餵一致性閘會把舊名字燒進新講者的聲紋。
    private var proposalGeneration = 0

    init(store: TranscriptStore, timeline: SpeakerTimeline) {
        self.store = store
        self.timeline = timeline
        self.apiKey = Keychain.openAIKey()
    }

    /// 30s 輪詢：有新輪替 + 距上輪 ≥60s + 近期看得到 ≥2 個講者代號才跑。
    func start() {
        guard apiKey != nil else {
            Telemetry.enrich.info("無 OpenAI key — 講者命名停用，分人維持代號")
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self.maybeRun()
            }
        }
    }

    private func maybeRun() async {
        guard !running, store.turnsVersion != lastVersion else { return }
        // 字母世代換了（剛 enroll 過）：舊提案作廢、舊輪替史丟掉（裡面的「講者 A」
        // 指向重排前的另一個人），這輪跳過 — 下一輪用乾淨素材重建
        if timeline.anonymousGeneration != proposalGeneration {
            proposalGeneration = timeline.anonymousGeneration
            lastNameProposals = [:]
            store.clearRecentTurns()
            lastVersion = store.turnsVersion
            return
        }
        let turns = speakerTurns()
        let letters = Set(turns.map(\.letter))
        guard letters.count >= 2 else { return }  // 單講者沒歸屬可推
        // 穩態降速：近期輪替裡每個講者都已有顯示名 → 10 分鐘才重驗一次（慢速自癒，
        // 防換內容後字母沿用造成的舊名殘留）；還有人沒名字 → 照常 60s
        let everyoneNamed = letters.allSatisfy { timeline.hasDisplayName(forLetter: $0) }
        guard Date().timeIntervalSince(lastRun) >= (everyoneNamed ? steadyInterval : interval) else { return }
        running = true
        defer { running = false }
        lastVersion = store.turnsVersion
        lastRun = Date()
        do {
            try await enrich(turns)
        } catch {
            Telemetry.enrich.error("enrich failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// recentTurns 裡帶講者代號的輪（app 來源的略過）；代號統一還原成字母。
    /// 帶時間範圍的輪先「重新解析」— commit 當下 diarizer 可能還沒收斂（換手點的
    /// 第一句常被掛錯人），讀時用收斂後的時間軸重查，吃到 tentative→finalized 的修訂。
    private func speakerTurns() -> [(letter: String, text: String)] {
        store.recentTurns.compactMap { turn in
            let label = turn.range.flatMap { store.speakerResolver?($0) } ?? turn.source
            guard let letter = timeline.canonicalLetter(for: label) else { return nil }
            return (letter, turn.text)
        }
    }

    private struct Attribution: Decodable {
        struct Speaker: Decodable {
            let label: String
            let role: String
            let name: String?
            let evidence: String?
            let confidence: Double
        }
        let speakers: [Speaker]
    }

    private func enrich(_ turns: [(letter: String, text: String)]) async throws {
        let rendered = turns.map { "講者 \($0.letter)：\($0.text.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "\n")
        let result: Attribution = try await complete(turns: rendered)

        let corpus = turns.map(\.text).joined()
        let normCorpus = Self.normalized(corpus)
        let phonCorpus = Self.phonetic(normCorpus)
        for s in result.speakers {  // raw 輸出觀測 — 調 prompt / 驗證規則的依據
            Telemetry.enrich.info("raw \(s.label, privacy: .public) role=\(s.role, privacy: .public) name=\(s.name ?? "∅", privacy: .public) conf=\(s.confidence, format: .fixed(precision: 2), privacy: .public) ev=\(String((s.evidence ?? "∅").prefix(40)), privacy: .public)")
        }
        var accepted: [(letter: String, role: String, name: String?)] = []
        for s in result.speakers where s.confidence >= 0.7 {
            let letter = s.label.replacingOccurrences(of: "講者 ", with: "")
            guard letter.count == 1, letter >= "A", letter <= "Z" else { continue }
            // 人名防幻覺：name 須出現在 corpus；evidence 須正規化後出現 — 比對都帶
            // 拼音容錯：ASR 同一個名字跨句轉出不同字（賴芳玉/賴方玉、博恩/伯恩），
            // exact 比對會讓防幻覺閘誤殺真名（實戰：自介句的名字被殺、錯的那方反而留名）
            let name = s.name.flatMap { n -> String? in
                guard corpus.contains(n) || phonCorpus.contains(Self.phonetic(Self.normalized(n))),
                      let e = s.evidence, !e.isEmpty,
                      normCorpus.contains(Self.normalized(e))
                        || phonCorpus.contains(Self.phonetic(Self.normalized(e)))
                else { return nil }
                return n
            }
            guard name != nil || s.role != "講者" else { continue }  // 無名 + 通用角色 = 沒資訊
            accepted.append((letter, s.role, name))
        }
        var names: [String: String] = [:]
        var personNames: [String: String] = [:]  // letter → 真人名（enroll 提案用，角色標籤不算）
        for a in accepted {
            // 有名字用名字；沒名字的一律「角色 + 字母」（主持人 A / 來賓 B）—
            // 未知身分永遠帶字母可區分，裸角色標會跟字母標混出幽靈第三人
            names[a.letter] = a.name ?? "\(a.role) \(a.letter)"
            if let n = a.name { personNames[a.letter] = n }
        }

        // 自我介紹硬覆蓋：「我是 X」是最強歸屬訊號，但 mini 屢次鏡像對調（實戰：B 說
        //「我是賴芳玉」仍被綁給 A，conf 0.98）— prompt 教不動就 code 層強制：
        // 誰的輪替裡說了「我是 X」，X 就綁給誰；同名從其他字母上拔掉（鏡像的另一半）。
        // 自介一致性檢查（不重綁！）：turn 的字母標籤在換手點不可靠 — 實測 diarizer
        // 漏抓第二講者時，自介句會被記在錯的字母下；先前用字母硬覆蓋反而把 LLM 靠
        // 內容推對的答案改錯。唯一字母無關的可靠約束：同一句裡「我是 N」的 N 與
        // 被呼喚的 V 必屬不同人 — LLM 把兩名掛同一字母 = 必錯，整輪撤名、不 enroll。
        let candidates = Set(result.speakers.compactMap(\.name))
            .filter { corpus.contains($0) || phonCorpus.contains(Self.phonetic(Self.normalized($0))) }
        var conflicted = false
        for hit in Self.selfIntroBindings(turns: turns, candidates: candidates) {
            let phonText = Self.phonetic(Self.normalized(hit.text))
            for voc in candidates where voc != hit.name
                && phonText.contains(Self.phonetic(Self.normalized(voc))) {
                // 同句出現 自介名 hit.name + 被喚名 voc → 兩名必屬不同字母
                let sameLetter = personNames.first { $0.value == hit.name }?.key
                    == personNames.first { $0.value == voc }?.key
                if sameLetter, personNames.values.contains(hit.name) {
                    Telemetry.enrich.info("self-intro conflict: \(hit.name, privacy: .public) 與 \(voc, privacy: .public) 被掛同字母 — 本輪撤名")
                    conflicted = true
                }
            }
        }
        if conflicted {
            personNames = [:]
            names = [:]
            for a in accepted where a.role != "講者" {
                names[a.letter] = "\(a.role) \(a.letter)"  // 撤名留角色+字母
            }
        }

        timeline.setDisplayNames(names)
        Telemetry.enrich.info("speaker map: \(names.map { "\($0.key)→\($0.value)" }.sorted().joined(separator: " "), privacy: .public)")
        // 閉環：推出真名 → 聲紋註冊。一致性閘：同一 letter→name 連續兩輪一致才 enroll —
        // mini 有 variance，單輪鏡像錯置會把錯名字燒進「持久的」聲紋庫
        //（displayNames 全量覆蓋可自癒，enroll 不行）。pump 內部另有 dedupe 與樣本量檢查。
        let proposals = personNames
        for (letter, name) in proposals where lastNameProposals[letter] == name {
            let ranges = timeline.segmentRanges(forLetter: letter)
            guard !ranges.isEmpty else { continue }
            Telemetry.enrich.info("enroll gate passed \(letter, privacy: .public)→\(name, privacy: .public)（連續兩輪一致）")
            pumpProvider?()?.requestEnroll(name: name, ranges: ranges)
        }
        lastNameProposals = proposals
    }

    /// 去標點、去空白、lowercase — 引句比對用的正規化。
    private static func normalized(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// 中文同音容錯：ASR 同一個名字跨句轉出不同字（賴芳玉/賴方玉、博恩/伯恩）—
    /// 轉拼音（mandarinToLatin，含調）後比對；非中文字元原樣保留小寫。
    private static func phonetic(_ s: String) -> String {
        let t = s.applyingTransform(.mandarinToLatin, reverse: false) ?? s
        return t.lowercased().replacingOccurrences(of: " ", with: "")
    }

    /// 掃輪替找自我介紹：哪個字母說了「我是 X / 我叫 X / I'm X」就把 X 綁給誰。
    /// 候選名限定 LLM 這輪有提出且（逐字或同音）在 corpus 出現的 — 不自己發明名字。
    /// 英文 marker 帶字界（\b）防 "him Sarah" 誤匹配；中文另走同音路徑 —
    /// marker 後取同長片段比拼音，吃下 ASR 跨句的同音變體（賴芳玉/賴方玉）。
    /// 回傳含命中的 turn 原文 — 呼喚反綁（同句裡被喚的名字是對方的）要用。
    private static func selfIntroBindings(turns: [(letter: String, text: String)],
                                          candidates: Set<String>)
        -> [(letter: String, name: String, text: String)] {
        guard !candidates.isEmpty else { return [] }
        var out: [(letter: String, name: String, text: String)] = []
        for (letter, text) in turns {
            for name in candidates {
                let esc = NSRegularExpression.escapedPattern(for: name)
                let pattern = "(我是|我叫|\\b[Ii] ?am\\b|\\b[Ii]'m|[Mm]y name is)[\\s,，、:：]*\(esc)"
                if text.range(of: pattern, options: .regularExpression) != nil {
                    out.append((letter, name, text))
                    continue
                }
                markerLoop: for marker in ["我是", "我叫"] {
                    var search = text.startIndex
                    while let r = text.range(of: marker, range: search..<text.endIndex) {
                        search = r.upperBound
                        let tail = text[r.upperBound...].drop { "，, 、：:。．.！!".contains($0) }
                        let head = String(tail.prefix(name.count))
                        if head.count == name.count, Self.phonetic(head) == Self.phonetic(name) {
                            out.append((letter, name, text))
                            break markerLoop
                        }
                    }
                }
            }
        }
        return out
    }

    /// chat completions + json_schema strict — 跟 polisher 同一條 API 通道。
    private func complete(turns: String) async throws -> Attribution {
        guard let apiKey else { throw NSError(domain: "Enrich", code: 0) }
        let instructions = """
            你是逐字稿的講者歸屬分析員。給你一段內容（影片/會議/podcast）的近期逐字稿輪替，\
            講者以代號標示。根據說話內容與彼此稱呼，判斷每個代號的角色與可能的名字。規則：
            - 稱呼語邏輯（最重要，想清楚再答）：講者句中出現的名字幾乎都是「對方」的名字 — \
            呼喚（「Sarah, 請說」）、感謝（「Thank you David」）、介紹來賓，都是在說別人；\
            把那個名字綁給「被稱呼的那一方」，不是說話者自己。\
            只有自我介紹（「我是 X」/ "I am X" / "my name is X"）才能把名字綁到說話者本人。\
            完整示例：講者 A 說「Sarah, tell us about…」、講者 B 說「Thank you David」\
            → A 在呼喚 Sarah，所以 Sarah 是 B；B 在感謝 David，所以 David 是 A。\
            結論：A=David、B=Sarah — 不要反過來
            - 介紹詞同理：「今天邀請到的是某某老師」是在介紹「對方」— 被介紹的名字屬於另一方，\
            絕不是說話者自己。完整示例 2：講者 A 說「邀請到的是林雅婷老師」、\
            講者 B 說「大明哥大家好，我是林雅婷」→ B 自我介紹了所以 B=林雅婷（不管別人怎麼提到她）；\
            B 呼喚大明哥所以那是 A 的稱呼。結論：A=大明哥、B=林雅婷 — 判成 A=林雅婷 是嚴重錯誤
            - 名字必須是逐字稿文字中實際出現過的字串，沒有就 null，絕不編造
            - 每個非 null 的 name 都要給 evidence：逐字稿中支持這個綁定的原句
            - 角色四選一：主持人、來賓、旁白、講者（旁白 = 無對話對象的敘述者；無法判斷用講者）
            - 有清楚依據（自我介紹、被呼喚、被介紹）就給名字，不要過度保守 — 寧可給出名字加上中等 confidence
            - confidence 0 到 1，不確定就低
            """
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "speakers": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "label": ["type": "string"],
                            "role": ["type": "string", "enum": ["主持人", "來賓", "旁白", "講者"]],
                            "name": ["type": ["string", "null"]],
                            "evidence": ["type": ["string", "null"]],
                            "confidence": ["type": "number"],
                        ],
                        "required": ["label", "role", "name", "evidence", "confidence"],
                        "additionalProperties": false,
                    ],
                ]
            ],
            "required": ["speakers"],
            "additionalProperties": false,
        ]
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": turns],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "speaker_attribution", "strict": true, "schema": schema],
            ],
            "max_completion_tokens": 600,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let content = (choices.first?["message"] as? [String: Any])?["content"] as? String,
              let parsed = try? JSONDecoder().decode(Attribution.self, from: Data(content.utf8))
        else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Enrich", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "attribution API error: \(body.prefix(200))"])
        }
        return parsed
    }
}
