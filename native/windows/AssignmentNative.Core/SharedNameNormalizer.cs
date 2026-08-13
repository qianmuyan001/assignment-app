using System.Text;

namespace AssignmentNative.Core;

public static class SharedNameNormalizer
{
    public static string Normalize(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        var normalized = value.Normalize(NormalizationForm.FormKC);
        var builder = new StringBuilder(normalized.Length);
        var pendingSpace = false;
        foreach (var rune in normalized.EnumerateRunes())
        {
            if (Rune.IsWhiteSpace(rune))
            {
                pendingSpace = builder.Length > 0;
                continue;
            }
            if (pendingSpace)
            {
                builder.Append(' ');
                pendingSpace = false;
            }

            // Unicode default case-fold mappings not represented by a simple
            // invariant lowercase operation. NFKC already expands ligatures.
            switch (rune.Value)
            {
                case 0x00DF: // LATIN SMALL LETTER SHARP S
                case 0x1E9E: // LATIN CAPITAL LETTER SHARP S
                    builder.Append("ss");
                    break;
                case 0x0130: // LATIN CAPITAL LETTER I WITH DOT ABOVE
                    builder.Append("i\u0307");
                    break;
                case 0x03C2: // GREEK SMALL LETTER FINAL SIGMA
                    builder.Append('\u03c3');
                    break;
                default:
                    builder.Append(rune.ToString().ToLowerInvariant());
                    break;
            }
        }
        return builder.ToString();
    }
}
