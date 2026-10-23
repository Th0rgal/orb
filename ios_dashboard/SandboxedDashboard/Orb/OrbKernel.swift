import Foundation

enum OrbKernel {
    struct WorkfoldVerdict {
        let foldItem: Bool
        let foldHasToolNext: Bool
    }

    static func workfoldStep(
        itemKind: Int,
        isCumulative: Bool,
        isNonEmpty: Bool,
        toolAhead: Bool,
        nextIsTool: Bool,
        foldHasTool: Bool
    ) -> WorkfoldVerdict {
        let raw: Int
        switch itemKind {
        case 3:
            raw = 257
        case 1:
            raw = foldHasTool ? 257 : 1
        case 2:
            if !isCumulative && isNonEmpty && toolAhead && (foldHasTool || nextIsTool) {
                raw = foldHasTool ? 257 : 1
            } else {
                raw = 0
            }
        default:
            raw = 0
        }
        return WorkfoldVerdict(foldItem: (raw & 1) != 0, foldHasToolNext: ((raw >> 8) & 1) != 0)
    }

    static func relativeTimeString(elapsedSecs: Int) -> String {
        let clamped = max(0, elapsedSecs)
        let raw: Int
        if clamped < 45 {
            raw = 0
        } else if clamped < 3600 {
            raw = 1 | (max(1, clamped / 60) << 8)
        } else if clamped < 86_400 {
            raw = 2 | ((clamped / 3600) << 8)
        } else if clamped < 604_800 {
            raw = 3 | ((clamped / 86_400) << 8)
        } else {
            raw = 4 | ((clamped / 604_800) << 8)
        }
        let unit = raw & 0xFF
        let value = (raw >> 8) & 0xFFFF_FFFF
        switch unit {
        case 0: return "now"
        case 1: return "\(value)m"
        case 2: return "\(value)h"
        case 3: return "\(value)d"
        default: return "\(value)w"
        }
    }

    static func usageLimitBadge(
        status: String,
        claim: String,
        hasUtilization: Bool,
        utilizationPct: Int,
        hasReset: Bool,
        resetRemSecs: Int
    ) -> (tone: String, label: String)? {
        let statusKind: Int
        switch status {
        case "", "allowed", "ok": statusKind = 0
        case "allowed_warning": statusKind = 1
        case "rejected": statusKind = 2
        default: statusKind = 3
        }
        let claimKind: Int
        switch claim {
        case "five_hour": claimKind = 1
        case "seven_day": claimKind = 2
        case "seven_day_opus": claimKind = 3
        case "seven_day_sonnet": claimKind = 4
        default: claimKind = 0
        }
        let clampedPct = min(100, max(0, utilizationPct))
        let rem = max(0, resetRemSecs)
        let raw: Int
        switch statusKind {
        case 0:
            raw = 0
        case 1:
            let win = (claimKind >= 1 && claimKind <= 4) ? (claimKind << 8) : 0
            let show = ((claimKind == 1 || claimKind == 2) && hasUtilization) ? 65536 : 0
            let pctBits = show != 0 ? (clampedPct << 24) : 0
            raw = 1 | win | show | pctBits
        case 2:
            if hasReset && rem > 0 {
                let mins = rem / 60
                let hrs = rem / 3600
                let days = rem / 86_400
                let unit = mins < 60 ? 1 : (hrs < 48 ? 2 : 3)
                let value = mins < 60 ? max(1, mins) : (hrs < 48 ? hrs : days)
                raw = 2 | (unit << 32) | (min(0xFFFFFF, value) << 40)
            } else {
                raw = 2
            }
        default:
            raw = 3
        }
        let tone = raw & 0xFF
        if tone == 0 { return nil }
        if tone == 1 {
            let winKind = (raw >> 8) & 0xFF
            let winLabel: String
            switch winKind {
            case 1: winLabel = "5h"
            case 2: winLabel = "weekly"
            case 3: winLabel = "weekly Opus"
            case 4: winLabel = "weekly Sonnet"
            default: return ("warning", "Approaching limit")
            }
            let showPct = ((raw >> 16) & 1) != 0
            let pct = (raw >> 24) & 0xFF
            let suffix = showPct ? " \(pct)%" : ""
            return ("warning", "Approaching limit · \(winLabel)\(suffix)")
        }
        if tone == 2 {
            let resetUnit = (raw >> 32) & 0xFF
            let resetVal = (raw >> 40) & 0xFFFFFF
            if resetUnit == 0 { return ("error", "Limit reached") }
            let unitSuffix = resetUnit == 1 ? "m" : (resetUnit == 2 ? "h" : "d")
            return ("error", "Limit reached · resets in \(resetVal)\(unitSuffix)")
        }
        return ("warning", "Limit status unknown")
    }

    static func gfmPipeRowAdmitted(rowLen: Int, colCount: Int, sepCols: Int, unterminatedEscape: Bool) -> Bool {
        colCount >= 1 && sepCols == colCount && !unterminatedEscape && rowLen >= 1
    }

    static func richTagAdmitted(tagLen: Int, attrLen: Int, tagKind: Int) -> Bool {
        (tagKind >= 1 && tagKind <= 4) && tagLen >= 3 && attrLen >= 1 && attrLen <= tagLen
    }
}
