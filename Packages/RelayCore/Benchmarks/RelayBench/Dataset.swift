import Foundation
import RelayCore

/// SplitMix64: a small, well-known deterministic generator. The same seed always
/// produces the same dataset, on any machine.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uuid() -> UUID {
        let a = next(), b = next()
        var bytes = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                     UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        withUnsafeMutableBytes(of: &bytes) { raw in
            raw.storeBytes(of: a, toByteOffset: 0, as: UInt64.self)
            raw.storeBytes(of: b, toByteOffset: 8, as: UInt64.self)
        }
        bytes.6 = (bytes.6 & 0x0F) | 0x40  // Version 4 layout, so it's a well-formed UUID.
        bytes.8 = (bytes.8 & 0x3F) | 0x80
        return UUID(uuid: bytes)
    }
}

/// Synthetic note content.
///
/// **Size distribution** (body length in characters; an assumption, not measured from
/// real users):
///
/// | Share | Body length | Stands for |
/// |---|---|---|
/// | 50% | 50–300 | quick notes, reminders |
/// | 35% | 300–2,000 | typical notes |
/// | 13% | 2,000–10,000 | long notes, meeting minutes |
/// | 2% | 10,000–50,000 | very long documents |
///
/// Lengths are uniform within each band. Titles are 2–7 words. Text is English words
/// from a fixed vocabulary, with a paragraph break about every 40 words. All ASCII, so
/// search results can be verified with plain lowercase matching.
enum Dataset {
    static let sizeBands: [(share: Double, range: ClosedRange<Int>)] = [
        (0.50, 50...300),
        (0.35, 300...2_000),
        (0.13, 2_000...10_000),
        (0.02, 10_000...50_000),
    ]

    /// Planted in exactly `fewMatchCount` notes; never produced otherwise.
    static let fewMatchToken = "zephyrquill"
    static let fewMatchCount = 10
    /// A vocabulary word, so it appears in many notes.
    static let manyMatchQuery = "meeting"
    /// Not in the vocabulary and never planted.
    static let noMatchQuery = "qxjvbrelaynomatch"

    static let vocabulary: [String] = """
        the of and to a in is it you that he was for on are with as his they be at one have this \
        from or had by hot word but what some we can out other were all there when up use your how \
        said an each she which do their time if will way about many then them write would like so \
        these her long make thing see him two has look more day could go come did number sound no \
        most people my over know water than call first who may down side been now find any new work \
        part take get place made live where after back little only round man year came show every \
        good me give our under name very through just form sentence great think say help low line \
        differ turn cause much mean before move right boy old too same tell does set three want air \
        well also play small end put home read hand port large spell add even land here must big high \
        such follow act why ask men change went light kind off need house picture try us again animal \
        point mother world near build self earth father head stand own page should country found \
        answer school grow study still learn plant cover food sun four between state keep eye never \
        last let thought city tree cross farm hard start might story saw far sea draw left late run \
        while press close night real life few north open seem together next white children begin got \
        walk example ease paper group always music those both mark often letter until mile river car \
        feet care second book carry took science eat room friend began idea fish mountain stop once \
        base hear horse cut sure watch color face wood main enough plain girl usual young ready above \
        ever red list though feel talk bird soon body dog family direct pose leave song measure door \
        product black short numeral class wind question happen complete ship area half rock order fire \
        south problem piece told knew pass since top whole king space heard best hour better true \
        during hundred five remember step early hold west ground interest reach fast verb sing listen \
        six table travel less morning ten simple several vowel toward war lay against pattern slow \
        center love person money serve appear road map rain rule govern pull cold notice voice unit \
        power town fine certain fly fall lead cry dark machine note wait plan figure star box noun \
        field rest correct able pound done beauty drive stood contain front teach week final gave \
        green oh quick develop ocean warm free minute strong special mind behind clear tail produce \
        fact street inch multiply nothing course stay wheel full force blue object decide surface deep \
        moon island foot system busy test record boat common gold possible plane stead dry wonder \
        laugh thousand ago ran check game shape equate miss brought heat snow tire bring yes distant \
        fill east paint language among meeting agenda project budget deadline review draft
        """.split(separator: " ").map(String.init)

    struct GeneratedNote {
        let id: UUID
        let title: String
        let body: String
    }

    static func bodyLength(using rng: inout SplitMix64) -> Int {
        let roll = Double(rng.next() >> 11) / Double(1 << 53)
        var cumulative = 0.0
        for band in sizeBands {
            cumulative += band.share
            if roll < cumulative { return Int.random(in: band.range, using: &rng) }
        }
        return Int.random(in: sizeBands.last!.range, using: &rng)
    }

    static func text(length: Int, using rng: inout SplitMix64) -> String {
        var result = ""
        result.reserveCapacity(length + 16)
        var wordsInParagraph = 0
        while result.utf8.count < length {
            if !result.isEmpty { result += wordsInParagraph >= 40 ? "\n\n" : " " }
            if wordsInParagraph >= 40 { wordsInParagraph = 0 }
            result += vocabulary[Int.random(in: 0..<vocabulary.count, using: &rng)]
            wordsInParagraph += 1
        }
        return result
    }

    static func title(using rng: inout SplitMix64) -> String {
        let words = Int.random(in: 2...7, using: &rng)
        return (0..<words).map { _ in vocabulary[Int.random(in: 0..<vocabulary.count, using: &rng)] }
            .joined(separator: " ")
            .capitalized
    }

    /// `count` notes generated from `seed`. Notes at evenly spaced indexes contain
    /// `fewMatchToken`.
    static func notes(count: Int, seed: UInt64) -> [GeneratedNote] {
        var rng = SplitMix64(seed: seed)
        let plantEvery = max(count / fewMatchCount, 1)
        return (0..<count).map { index in
            let id = rng.uuid()
            let title = title(using: &rng)
            var body = text(length: bodyLength(using: &rng), using: &rng)
            if index % plantEvery == plantEvery / 2, index / plantEvery < fewMatchCount {
                body += " \(fewMatchToken)"
            }
            return GeneratedNote(id: id, title: title, body: body)
        }
    }

    /// What a note looks like when it was downloaded from iCloud: present locally,
    /// synced, with a server change tag.
    static func remote(_ note: GeneratedNote, tag: String, created: Date, isDeleted: Bool = false) -> RemoteNote {
        RemoteNote(
            id: note.id, title: isDeleted ? "" : note.title, body: isDeleted ? "" : note.body,
            createdAt: created, modifiedAt: created, isDeleted: isDeleted,
            changeTag: tag, systemFields: Data(tag.utf8)
        )
    }
}
