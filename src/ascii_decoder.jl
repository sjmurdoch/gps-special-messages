# GPS Special Message decoder
# Converts the 176-bit special message content to 22-character UTF-8 string
#
# Character encoding: Messages are decoded as Code Page 437 (original IBM PC character set)
# and converted to UTF-8 for storage and display.
#
# Bit correction is handled at the word level in lnav_decoder.jl:
# - Frame-level inversion: detected via HOW TOW verification
# - D30* un-complementing: applied per-word based on previous word's D30 parity bit
# This produces correct source data bits, so all bytes decode directly as CP437.

using Dates

# Code Page 437 to Unicode mapping table
# CP437 is the original IBM PC character set. Characters 0-127 are mostly ASCII,
# while 128-255 contain box drawing, accented letters, Greek letters, and math symbols.
const CP437_TO_UNICODE = Char[
    # 0x00-0x0F: Control characters and symbols
    '\0',     '☺',     '☻',     '♥',     '♦',     '♣',     '♠',     '•',
    '◘',     '○',     '◙',     '♂',     '♀',     '♪',     '♫',     '☼',
    # 0x10-0x1F: More symbols
    '►',     '◄',     '↕',     '‼',     '¶',     '§',     '▬',     '↨',
    '↑',     '↓',     '→',     '←',     '∟',     '↔',     '▲',     '▼',
    # 0x20-0x2F: ASCII punctuation and digits
    ' ',     '!',     '"',     '#',     '$',     '%',     '&',     '\'',
    '(',     ')',     '*',     '+',     ',',     '-',     '.',     '/',
    # 0x30-0x3F: Digits and punctuation
    '0',     '1',     '2',     '3',     '4',     '5',     '6',     '7',
    '8',     '9',     ':',     ';',     '<',     '=',     '>',     '?',
    # 0x40-0x4F: @ and uppercase A-O
    '@',     'A',     'B',     'C',     'D',     'E',     'F',     'G',
    'H',     'I',     'J',     'K',     'L',     'M',     'N',     'O',
    # 0x50-0x5F: Uppercase P-Z and punctuation
    'P',     'Q',     'R',     'S',     'T',     'U',     'V',     'W',
    'X',     'Y',     'Z',     '[',     '\\',    ']',     '^',     '_',
    # 0x60-0x6F: Backtick and lowercase a-o
    '`',     'a',     'b',     'c',     'd',     'e',     'f',     'g',
    'h',     'i',     'j',     'k',     'l',     'm',     'n',     'o',
    # 0x70-0x7F: Lowercase p-z, punctuation, and house
    'p',     'q',     'r',     's',     't',     'u',     'v',     'w',
    'x',     'y',     'z',     '{',     '|',     '}',     '~',     '⌂',
    # 0x80-0x8F: Accented letters
    'Ç',     'ü',     'é',     'â',     'ä',     'à',     'å',     'ç',
    'ê',     'ë',     'è',     'ï',     'î',     'ì',     'Ä',     'Å',
    # 0x90-0x9F: More accented letters
    'É',     'æ',     'Æ',     'ô',     'ö',     'ò',     'û',     'ù',
    'ÿ',     'Ö',     'Ü',     '¢',     '£',     '¥',     '₧',     'ƒ',
    # 0xA0-0xAF: Accented letters and symbols
    'á',     'í',     'ó',     'ú',     'ñ',     'Ñ',     'ª',     'º',
    '¿',     '⌐',     '¬',     '½',     '¼',     '¡',     '«',     '»',
    # 0xB0-0xBF: Box drawing light
    '░',     '▒',     '▓',     '│',     '┤',     '╡',     '╢',     '╖',
    '╕',     '╣',     '║',     '╗',     '╝',     '╜',     '╛',     '┐',
    # 0xC0-0xCF: Box drawing continued
    '└',     '┴',     '┬',     '├',     '─',     '┼',     '╞',     '╟',
    '╚',     '╔',     '╩',     '╦',     '╠',     '═',     '╬',     '╧',
    # 0xD0-0xDF: Box drawing continued
    '╨',     '╤',     '╥',     '╙',     '╘',     '╒',     '╓',     '╫',
    '╪',     '┘',     '┌',     '█',     '▄',     '▌',     '▐',     '▀',
    # 0xE0-0xEF: Greek letters and math
    'α',     'ß',     'Γ',     'π',     'Σ',     'σ',     'µ',     'τ',
    'Φ',     'Θ',     'Ω',     'δ',     '∞',     'φ',     'ε',     '∩',
    # 0xF0-0xFF: Math symbols and special
    '≡',     '±',     '≥',     '≤',     '⌠',     '⌡',     '÷',     '≈',
    '°',     '∙',     '·',     '√',     'ⁿ',     '²',     '■',     ' '
]

"""
    cp437_to_utf8(byte::UInt8) -> Char

Convert a Code Page 437 byte to its Unicode equivalent.
"""
@inline cp437_to_utf8(byte::UInt8)::Char = CP437_TO_UNICODE[Int(byte) + 1]

"""
    decode_special_message(bytes::Vector{UInt8}) -> String

Decode 22 bytes of special message content to a UTF-8 string.
All bytes are converted from CP437 encoding to UTF-8.
Null bytes (0x00) are rendered as the Unicode replacement character (U+FFFD).
"""
function decode_special_message(bytes::Vector{UInt8})::String
    @boundscheck length(bytes) == 22 || throw(ArgumentError("Expected 22 bytes, got $(length(bytes))"))
    io = IOBuffer()
    for i in 1:22
        byte = bytes[i]
        if byte == 0x00
            print(io, '�')
        else
            print(io, cp437_to_utf8(byte))
        end
    end
    return String(take!(io))
end

"""
    DecodedSpecialMessage

A fully decoded GPS special message with metadata.
"""
struct DecodedSpecialMessage
    time::Int32              # Seconds of day from Arrow file
    datetime::DateTime       # Full datetime computed from year, doy, time
    prn::Int                 # Satellite PRN
    sv_id::Int               # SV ID (always 55 for Page 17)
    alert_flag::Bool         # Alert flag from HOW
    raw_bytes::Vector{UInt8} # Raw 22 bytes of message (source data after D30* un-complementing)
    ascii_message::String    # Decoded message (UTF-8, converted from CP437)
    frame_inverted::Bool     # Whether the whole frame was bit-inverted (detected via HOW)
    parity_ok::Bool          # Whether all words passed LNAV parity check
end

"""
    make_datetime(year::Int, day_of_year::Int, seconds_of_day::Int) -> DateTime

Create a DateTime from year, day of year, and seconds of day.
"""
function make_datetime(year::Int, day_of_year::Int, seconds_of_day::Int)::DateTime
    base_date = Date(year, 1, 1) + Day(day_of_year - 1)
    hours = seconds_of_day ÷ 3600
    minutes = (seconds_of_day % 3600) ÷ 60
    seconds = seconds_of_day % 60
    return DateTime(base_date) + Hour(hours) + Minute(minutes) + Second(seconds)
end

"""
    decode_frame(packed::AbstractVector{UInt8}, time::Int32, prn::Int, year::Int, day_of_year::Int) -> DecodedSpecialMessage

Decode a complete special message frame.
Assumes the frame has already been validated as Subframe 4, Page 17.

Uses parity to determine the correct bit state: first tries direct parity check,
then tries with D30* un-complementing. Whichever passes determines how message
bits are extracted. This replaces per-character bit inversion with a principled
word-level approach.
"""
function decode_frame(packed::AbstractVector{UInt8}, time::Int32, prn::Int, year::Int, day_of_year::Int)::DecodedSpecialMessage
    # Parse frame to get alert flag and inversion status
    frame_info = parse_frame(packed, Int(time))

    # Use parity to determine if D30* un-complementing is needed:
    # 1. Try parity without D30* un-complementing (data already clean)
    # 2. If that fails, try with D30* un-complementing (data has D30* applied)
    # 3. Use whichever mode passes parity for bit extraction
    parity_direct = check_message_parity(packed, frame_info.inverted, false)
    if parity_direct
        parity_ok = true
        d30_uncomp = false
    else
        parity_d30 = check_message_parity(packed, frame_info.inverted, true)
        parity_ok = parity_d30
        d30_uncomp = parity_d30
    end

    # Extract message bits using the parity-determined mode
    raw_bytes = extract_special_message_bits(packed, frame_info.inverted, d30_uncomp)

    # Decode message from CP437 to UTF-8
    ascii_message = decode_special_message(raw_bytes)

    # Create datetime
    dt = make_datetime(year, day_of_year, Int(time))

    return DecodedSpecialMessage(
        time,
        dt,
        prn,
        frame_info.sv_id !== nothing ? frame_info.sv_id : PAGE_17_SV_ID,
        frame_info.alert_flag,
        raw_bytes,
        ascii_message,
        frame_info.inverted,
        parity_ok
    )
end

"""
    format_message(msg::DecodedSpecialMessage) -> String

Format a decoded message for logging output (UTF-8).
"""
function format_message(msg::DecodedSpecialMessage)::String
    date_str = Dates.format(msg.datetime, "yyyy-mm-dd HH:MM:SS")
    alert_str = msg.alert_flag ? "1" : "0"
    frame_inv_str = msg.frame_inverted ? "1" : "0"
    parity_str = msg.parity_ok ? "OK" : "FAIL"
    return "[$date_str] PRN=$(lpad(msg.prn, 2, '0')) SV_ID=$(msg.sv_id) Alert=$alert_str FrameInv=$frame_inv_str Parity=$parity_str Message=\"$(msg.ascii_message)\""
end

# Pretty printing
function Base.show(io::IO, msg::DecodedSpecialMessage)
    print(io, format_message(msg))
end
