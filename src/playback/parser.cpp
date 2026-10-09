#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <limits>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>
#include "parser.h"

using namespace std;

namespace {

class MidiReader {
public:
    explicit MidiReader(span<const uint8_t> bytes) : bytes_(bytes) {}

    size_t remaining() const { return bytes_.size() - position_; }

    uint8_t byte() {
        if (remaining() < 1) {
            throw runtime_error("Unexpected end of MIDI data");
        }
        return bytes_[position_++];
    }

    uint16_t big_endian_u16() {
        return static_cast<uint16_t>(byte()) << 8 | byte();
    }

    uint32_t big_endian_u32() {
        return static_cast<uint32_t>(byte()) << 24 |
               static_cast<uint32_t>(byte()) << 16 |
               static_cast<uint32_t>(byte()) << 8 |
               byte();
    }

    uint32_t variable_length() {
        uint32_t value = 0;
        for (int i = 0; i < 4; ++i) {
            const uint8_t next = byte();
            value = (value << 7) | (next & 0x7f);
            if ((next & 0x80) == 0) {
                return value;
            }
        }
        throw runtime_error("Invalid MIDI variable-length value");
    }

    bool marker(string_view value) {
        if (remaining() < value.size()) {
            throw runtime_error("Unexpected end of MIDI data");
        }
        const bool matches = equal(value.begin(), value.end(),
                                   bytes_.begin() + static_cast<ptrdiff_t>(position_));
        position_ += value.size();
        return matches;
    }

    string text(size_t length) {
        if (remaining() < length) {
            throw runtime_error("Truncated MIDI text event");
        }
        string value;
        if (length > 0) {
            value.assign(reinterpret_cast<const char*>(bytes_.data() + position_), length);
        }
        position_ += length;
        value.erase(remove(value.begin(), value.end(), '\0'), value.end());
        return value;
    }

    span<const uint8_t> bytes(size_t length) {
        if (remaining() < length) {
            throw runtime_error("Truncated MIDI track");
        }
        const span<const uint8_t> value = bytes_.subspan(position_, length);
        position_ += length;
        return value;
    }

    void skip(size_t length) {
        if (remaining() < length) {
            throw runtime_error("Truncated MIDI event");
        }
        position_ += length;
    }

private:
    span<const uint8_t> bytes_;
    size_t position_ = 0;
};

struct MidiRawNote {
    uint64_t tick;
    uint8_t pitch;
};

struct MidiTempoChange {
    uint64_t tick;
    uint32_t microseconds_per_quarter;
};

struct MidiTempoSegment {
    uint64_t tick;
    uint32_t microseconds_per_quarter;
    long double elapsed_microseconds;
};

struct MidiData {
    vector<MidiRawNote> notes;
    array<size_t, 128> pitch_counts{};
    vector<MidiTempoChange> tempos;
    string title;
    int8_t key_sharps_flats = 0;
    bool key_minor = false;
    bool has_key_signature = false;
    uint16_t division = 0;
};

vector<uint8_t> read_binary_file(const string& path) {
    ifstream file(path, ios::binary);
    if (!file.is_open()) {
        throw runtime_error("Unable to open MIDI file: " + path);
    }

    file.seekg(0, ios::end);
    const streamoff size = file.tellg();
    if (size < 0) {
        throw runtime_error("Unable to read MIDI file: " + path);
    }
    file.seekg(0, ios::beg);

    vector<uint8_t> bytes(static_cast<size_t>(size));
    if (!bytes.empty() && !file.read(reinterpret_cast<char*>(bytes.data()), size)) {
        throw runtime_error("Unable to read MIDI file: " + path);
    }
    return bytes;
}

void parse_midi_track(span<const uint8_t> bytes, MidiData& result) {
    MidiReader reader(bytes);
    uint64_t tick = 0;
    uint8_t running_status = 0;

    while (reader.remaining() > 0) {
        tick += reader.variable_length();
        const uint8_t first = reader.byte();
        const bool has_running_data = first < 0x80;
        const uint8_t status = has_running_data ? running_status : first;
        if (status < 0x80) {
            throw runtime_error("MIDI event is missing running status");
        }

        const uint8_t first_data = has_running_data ? first : 0;
        if (!has_running_data && status >= 0x80 && status <= 0xef) {
            running_status = status;
        }

        if (status == 0xff) {
            running_status = 0;
            const uint8_t meta_type = reader.byte();
            const uint32_t length = reader.variable_length();
            if (meta_type == 0x03) {
                const string track_title = reader.text(length);
                if (result.title.empty() && !track_title.empty()) {
                    result.title = track_title;
                }
            } else if (meta_type == 0x51 && length == 3) {
                const uint32_t tempo = static_cast<uint32_t>(reader.byte()) << 16 |
                                       static_cast<uint32_t>(reader.byte()) << 8 |
                                       reader.byte();
                if (tempo == 0) {
                    throw runtime_error("MIDI tempo cannot be zero");
                }
                result.tempos.push_back({tick, tempo});
            } else if (meta_type == 0x59 && length == 2) {
                const uint8_t encoded_sharps_flats = reader.byte();
                const uint8_t mode = reader.byte();
                const int8_t sharps_flats = static_cast<int8_t>(encoded_sharps_flats);

                if (sharps_flats >= -7 && sharps_flats <= 7 && mode <= 1 &&
                    !result.has_key_signature && tick == 0) {
                    result.key_sharps_flats = sharps_flats;
                    result.key_minor = mode == 1;
                    result.has_key_signature = true;
                }
            } else {
                reader.skip(length);
            }
            if (meta_type == 0x2f) {
                return;
            }
            continue;
        }

        if (status == 0xf0 || status == 0xf7) {
            running_status = 0;
            reader.skip(reader.variable_length());
            continue;
        }

        const uint8_t event = status & 0xf0;
        if (event == 0x90 || event == 0x80) {
            const uint8_t pitch = has_running_data ? first_data : reader.byte();
            const uint8_t velocity = reader.byte();
            if (event == 0x90 && velocity != 0) {
                result.notes.push_back({tick, pitch});
                ++result.pitch_counts[pitch];
            }
            continue;
        }

        if (event == 0xc0 || event == 0xd0) {
            if (!has_running_data) {
                reader.skip(1);
            }
            continue;
        }

        if (event == 0xa0 || event == 0xb0 || event == 0xe0) {
            reader.skip(has_running_data ? 1 : 2);
            continue;
        }

        // System common messages are uncommon in Standard MIDI Files, but
        // consuming their data keeps a valid file parseable if they appear.
        running_status = 0;
        if (status == 0xf1 || status == 0xf3) {
            reader.skip(1);
        } else if (status == 0xf2) {
            reader.skip(2);
        } else if (status == 0xf6) {
            continue;
        } else {
            throw runtime_error("Unsupported MIDI event");
        }
    }
}

MidiData parse_midi_file(const string& path) {
    const vector<uint8_t> bytes = read_binary_file(path);
    MidiReader reader(span<const uint8_t>(bytes.data(), bytes.size()));
    if (reader.remaining() < 14 || !reader.marker("MThd")) {
        throw runtime_error("Invalid MIDI header");
    }

    const uint32_t header_length = reader.big_endian_u32();
    if (header_length < 6 || reader.remaining() < header_length) {
        throw runtime_error("Invalid MIDI header length");
    }
    const uint16_t format = reader.big_endian_u16();
    const uint16_t track_count = reader.big_endian_u16();
    const uint16_t division = reader.big_endian_u16();
    reader.skip(header_length - 6);

    if (format > 2) {
        throw runtime_error("Unsupported MIDI format");
    }
    if (format == 2) {
        throw runtime_error("MIDI format 2 is not supported");
    }
    if (track_count == 0 || (format == 0 && track_count != 1) ||
        (division & 0x8000) != 0 || division == 0) {
        throw runtime_error("MIDI must use a positive ticks-per-quarter division");
    }

    MidiData result;
    result.division = division;
    for (uint16_t track = 0; track < track_count; ++track) {
        if (reader.remaining() < 8 || !reader.marker("MTrk")) {
            throw runtime_error("Invalid MIDI track header");
        }
        const uint32_t track_length = reader.big_endian_u32();
        result.notes.reserve(result.notes.size() + track_length / 4);
        parse_midi_track(reader.bytes(track_length), result);
    }
    return result;
}

int8_t lyre_key_index(uint8_t pitch) {
    static constexpr array<int8_t, 128> indices = [] {
        array<int8_t, 128> value{};
        value.fill(-1);
        constexpr array<uint8_t, 21> pitches = {
            72, 74, 76, 77, 79, 81, 83,
            60, 62, 64, 65, 67, 69, 71,
            48, 50, 52, 53, 55, 57, 59
        };
        for (size_t index = 0; index < pitches.size(); ++index) {
            value[pitches[index]] = static_cast<int8_t>(index);
        }
        return value;
    }();
    return indices[pitch];
}

int midi_tonic_pitch_class(const KeySignature& key_signature) {
    static constexpr array<int, 15> major_tonics = {
        11, 6, 1, 8, 3, 10, 5, 0,
         7, 2, 9, 4, 11, 6, 1
    };
    static constexpr array<int, 15> minor_tonics = {
         8, 3, 10, 5, 0, 7, 2, 9,
         4, 11, 6, 1, 8, 3, 10
    };
    const int index = static_cast<int>(key_signature.sharps_flats) + 7;
    if (index < 0 || index >= 15) {
        throw runtime_error("Invalid MIDI key signature");
    }
    return (key_signature.minor ? minor_tonics : major_tonics)[static_cast<size_t>(index)];
}

int midi_base_transposition(const KeySignature& key_signature) {
    const int target = key_signature.minor ? 9 : 0;  // A minor or C major.
    int shift = target - midi_tonic_pitch_class(key_signature);
    while (shift > 6) {
        shift -= 12;
    }
    while (shift < -6) {
        shift += 12;
    }
    return shift;
}

int calculate_raw_transposition(const array<size_t, 128>& pitch_counts,
                                const KeySignature& key_signature) {
    const int base = midi_base_transposition(key_signature);
    int best_shift = base;
    size_t best_playable_count = 0;
    bool have_best = false;

    for (int octave = -2; octave <= 2; ++octave) {
        const int candidate = base + octave * 12;
        size_t playable_count = 0;
        for (size_t pitch = 0; pitch < pitch_counts.size(); ++pitch) {
            if (pitch_counts[pitch] == 0) {
                continue;
            }
            const int shifted_pitch = static_cast<int>(pitch) + candidate;
            if (shifted_pitch >= 0 && shifted_pitch <= 127 &&
                lyre_key_index(static_cast<uint8_t>(shifted_pitch)) >= 0) {
                playable_count += pitch_counts[pitch];
            }
        }
        if (!have_best || playable_count > best_playable_count ||
            (playable_count == best_playable_count &&
             std::abs(candidate) < std::abs(best_shift))) {
            best_shift = candidate;
            best_playable_count = playable_count;
            have_best = true;
        }
    }
    return best_shift;
}

vector<MidiTempoSegment> build_tempo_segments(
    vector<MidiTempoChange> tempos, uint16_t division) {
    sort(tempos.begin(), tempos.end(), [](const MidiTempoChange& a,
                                         const MidiTempoChange& b) {
        return a.tick < b.tick;
    });

    vector<MidiTempoChange> effective;
    for (const MidiTempoChange& tempo : tempos) {
        if (!effective.empty() && effective.back().tick == tempo.tick) {
            effective.back() = tempo;
        } else {
            effective.push_back(tempo);
        }
    }

    vector<MidiTempoSegment> segments{{0, 500000, 0.0L}};
    uint64_t previous_tick = 0;
    uint32_t current_tempo = 500000;  // MIDI default: 120 BPM.
    for (const MidiTempoChange& tempo : effective) {
        if (tempo.tick == 0) {
            segments.front().microseconds_per_quarter = tempo.microseconds_per_quarter;
            current_tempo = tempo.microseconds_per_quarter;
            continue;
        }
        const long double elapsed = segments.back().elapsed_microseconds +
            static_cast<long double>(tempo.tick - previous_tick) *
            current_tempo / division;
        segments.push_back({tempo.tick, tempo.microseconds_per_quarter, elapsed});
        previous_tick = tempo.tick;
        current_tempo = tempo.microseconds_per_quarter;
    }
    return segments;
}

bool is_midi_path(const string& path) {
    string extension = filesystem::path(path).extension().string();
    transform(extension.begin(), extension.end(), extension.begin(),
              [](unsigned char c) { return static_cast<char>(tolower(c)); });
    return extension == ".mid" || extension == ".midi";
}

}  // namespace

char midi_to_key(uint8_t pitch) {
    static constexpr char keys[] = "QWERTYUASDFGHJZXCVBNM";
    const int8_t index = lyre_key_index(pitch);
    return index < 0 ? '\0' : keys[index];
}

bool is_lyre_playable_pitch(int pitch) {
    if (pitch < 0 || pitch > 127) {
        return false;
    }
    return lyre_key_index(static_cast<uint8_t>(pitch)) >= 0;
}

int calculate_base_transposition(const KeySignature& key_signature) {
    return midi_base_transposition(key_signature);
}

int calculate_transposition(const vector<MidiNote>& notes,
                            const KeySignature& key_signature) {
    const int base = calculate_base_transposition(key_signature);
    int best_shift = base;
    size_t best_playable_count = 0;
    bool have_best = false;

    // Octave-equivalent shifts keep the key relationship intact while moving
    // the melody into the lyre's three-octave register.
    for (int octave = -2; octave <= 2; ++octave) {
        const int candidate = base + octave * 12;
        size_t playable_count = 0;
        for (const MidiNote& note : notes) {
            const int shifted_pitch = static_cast<int>(note.pitch) + candidate;
            if (is_lyre_playable_pitch(shifted_pitch)) {
                ++playable_count;
            }
        }

        if (!have_best || playable_count > best_playable_count ||
            (playable_count == best_playable_count &&
             std::abs(candidate) < std::abs(best_shift))) {
            best_shift = candidate;
            best_playable_count = playable_count;
            have_best = true;
        }
    }
    return best_shift;
}

bool transpose_notes(vector<MidiNote>& notes, int semitones) {
    bool all_in_midi_range = true;
    for (MidiNote& note : notes) {
        const int shifted_pitch = static_cast<int>(note.pitch) + semitones;
        if (shifted_pitch < 0 || shifted_pitch > 127) {
            all_in_midi_range = false;
        } else {
            note.pitch = static_cast<uint8_t>(shifted_pitch);
        }
    }
    return all_in_midi_range;
}

GenshinSheetParser::GenshinSheetParser(string file_path)
    : file_path(file_path) {
        index_map[0] = Key::Q;
        index_map[1] = Key::W;
        index_map[2] = Key::E;
        index_map[3] = Key::R;
        index_map[4] = Key::T;
        index_map[5] = Key::Y;
        index_map[6] = Key::U;

        index_map[7] = Key::A;
        index_map[8] = Key::S;
        index_map[9] = Key::D;
        index_map[10] = Key::F;
        index_map[11] = Key::G;
        index_map[12] = Key::H;
        index_map[13] = Key::J;

        index_map[14] = Key::Z;
        index_map[15] = Key::X;
        index_map[16] = Key::C;
        index_map[17] = Key::V;
        index_map[18] = Key::B;
        index_map[19] = Key::N;
        index_map[20] = Key::M;
}

json GenshinSheetParser::parse() {
    ifstream file(file_path);
    if (!file.is_open()) {
        throw runtime_error("Unable to open sheet: " + file_path);
    }

    json song;
    file >> song;

    if (!song.is_array() || song.empty() || (!song[0].contains("notes") && !song[0].contains("columns"))) {
        throw runtime_error("Invalid .genshinsheet document");
    }

    metadata.title = song[0].value("name", "Untitled");
    const int bpm = song[0].value("bpm", 0);
    if (bpm <= 0) {
        throw runtime_error("Invalid sheet tempo");
    }
    metadata.bpm = bpm;
    metadata.type = song[0].value("type", "composed") == "composed" ? Composed : Recorded;

    return song;
}

vector<ComposedNote> GenshinSheetParser::parse_composed(json song) {
    const double ms_per_beat = 60000.0 / metadata.bpm;
    vector<ComposedNote> song_notes;
    double time = 0.0;

    for (auto& column : song[0]["columns"]) {
        const int tempo_index = column[0].get<int>();
        const double amount = 1 / pow(2.0, tempo_index);

        vector<int> note_indices;
        for (auto& note : column[1]) {
            note_indices.push_back(note[0].get<int>());
        }

        // Empty columns are rests: they still advance time but emit no note.
        if (!note_indices.empty()) {
            song_notes.push_back(ComposedNote{
                note_indices,
                static_cast<int>(time)
            });
        }
        time += ms_per_beat * amount;
    }
    return song_notes;
}

vector<RecordedNote> GenshinSheetParser::parse_recorded(json song) {
    vector<RecordedNote> song_notes;
    for (auto note : song[0]["notes"]) {
        song_notes.push_back(RecordedNote{
            note[0],
            note[1]
        });
    }
    return song_notes;
}

vector<Note> GenshinSheetParser::translate_composed(json song) {
    vector<ComposedNote> song_notes = parse_composed(song);
    vector<Note> result;

    if (song_notes.empty()) {
        return result;
    }

    for (const auto& note : song_notes) {

        vector<Key> keys;
        int currentTime = note.time;

        for (int index : note.note_index) {
            const Key key = index_map.at(index);
            if (find(keys.begin(), keys.end(), key) == keys.end()) {
                keys.push_back(key);
            }
        }

        result.emplace_back(
            keys,
            chrono::milliseconds(currentTime)
        );
    }
    return result;
}

vector<Note> GenshinSheetParser::translate_recorded(json song) {
    vector<RecordedNote> song_notes = parse_recorded(song);
    vector<Note> result;

    if (song_notes.empty()) {
        return result;
    }

    vector<Key> keys;
    int currentTime = song_notes[0].time;

    for (const auto& note : song_notes) {

        if (note.time != currentTime) {

            result.emplace_back(
                keys,
                chrono::milliseconds(currentTime)
            );

            keys.clear();
            currentTime = note.time;
        }

        const Key key = index_map.at(note.note_index);
        if (find(keys.begin(), keys.end(), key) == keys.end()) {
            keys.push_back(key);
        }
    }

    if (!keys.empty()) {
        result.emplace_back(
            keys,
            chrono::milliseconds(currentTime)
        );
    }
    return result;
}

namespace {

// Strict UTF-8 check (rejects overlongs, surrogates, and > U+10FFFF).
bool is_valid_utf8(const string& text) {
    size_t i = 0;
    const size_t n = text.size();
    while (i < n) {
        const unsigned char c = static_cast<unsigned char>(text[i]);
        size_t extra = 0;
        uint32_t cp = 0;
        if (c < 0x80) { ++i; continue; }
        else if ((c & 0xE0) == 0xC0) { extra = 1; cp = c & 0x1F; }
        else if ((c & 0xF0) == 0xE0) { extra = 2; cp = c & 0x0F; }
        else if ((c & 0xF8) == 0xF0) { extra = 3; cp = c & 0x07; }
        else return false;
        for (size_t k = 1; k <= extra; ++k) {
            if (i + k >= n) return false;
            const unsigned char cc = static_cast<unsigned char>(text[i + k]);
            if ((cc & 0xC0) != 0x80) return false;
            cp = (cp << 6) | (cc & 0x3F);
        }
        static constexpr uint32_t kMin[4] = {0, 0x80, 0x800, 0x10000};
        if (cp < kMin[extra] || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return false;
        i += extra + 1;
    }
    return true;
}

bool is_blank(const string& text) {
    return all_of(text.begin(), text.end(),
                  [](unsigned char c) { return isspace(c) || c == 0; });
}

}  // namespace

vector<Note> GenshinSheetParser::translate_midi() {
    MidiData midi = parse_midi_file(file_path);
    metadata.type = Midi;

    const vector<MidiTempoSegment> tempo_segments =
        build_tempo_segments(std::move(midi.tempos), midi.division);
    const uint32_t first_tempo = tempo_segments.front().microseconds_per_quarter;
    metadata.bpm = static_cast<int>(llround(60000000.0 / first_tempo));
    // MIDI track names carry no encoding, and many exporters mangle non-Latin
    // text (e.g. one byte per CJK character), so the bytes can't be decoded.
    // When the embedded name isn't clean UTF-8, use the file name instead,
    // which the filesystem always stores as proper UTF-8.
    metadata.title = midi.title;
    if (metadata.title.empty() || is_blank(metadata.title) ||
        !is_valid_utf8(metadata.title)) {
        metadata.title = filesystem::path(file_path).stem().string();
    }
    if (metadata.title.empty()) {
        metadata.title = "Untitled";
    }

    sort(midi.notes.begin(), midi.notes.end(), [](const MidiRawNote& a,
                                                 const MidiRawNote& b) {
        if (a.tick != b.tick) {
            return a.tick < b.tick;
        }
        return a.pitch < b.pitch;
    });

    const KeySignature key_signature{
        static_cast<int8_t>(midi.has_key_signature ? midi.key_sharps_flats : 0),
        midi.has_key_signature && midi.key_minor
    };
    const int transposition = calculate_raw_transposition(midi.pitch_counts, key_signature);
    vector<Note> result;
    result.reserve(midi.notes.size());
    uint64_t result_tick = numeric_limits<uint64_t>::max();
    array<bool, 21> chord_keys{};
    size_t tempo_index = 0;
    for (size_t index = 0; index < midi.notes.size(); ++index) {
        const MidiRawNote& raw = midi.notes[index];
        const int transposed_pitch = static_cast<int>(raw.pitch) + transposition;
        const int key_index = transposed_pitch >= 0 && transposed_pitch <= 127
            ? lyre_key_index(static_cast<uint8_t>(transposed_pitch)) : -1;
        if (key_index < 0) {
            continue;
        }

        const Key key = static_cast<Key>(key_index);

        while (tempo_index + 1 < tempo_segments.size() &&
               tempo_segments[tempo_index + 1].tick <= raw.tick) {
            ++tempo_index;
        }
        const MidiTempoSegment& segment = tempo_segments[tempo_index];
        const long double elapsed_microseconds = segment.elapsed_microseconds +
            static_cast<long double>(raw.tick - segment.tick) *
            segment.microseconds_per_quarter / midi.division;
        const auto timestamp = chrono::milliseconds(static_cast<long long>(llround(
            elapsed_microseconds / 1000.0L)));
        if (result.empty() || result_tick != raw.tick) {
            result.emplace_back(vector<Key>{key}, timestamp);
            result_tick = raw.tick;
            chord_keys.fill(false);
            chord_keys[static_cast<size_t>(key_index)] = true;
            continue;
        }

        if (!chord_keys[static_cast<size_t>(key_index)]) {
            result.back().keys.push_back(key);
            chord_keys[static_cast<size_t>(key_index)] = true;
        }
    }

    return result;
}

namespace {

// Notes that start within this window of a chord's first note are one chord.
// Humanized MIDI and recorded sheets spread a "simultaneous" chord over a few
// milliseconds, which would otherwise play (and be practiced) as separate
// notes. Anchored to the chord's first note so fast runs never chain together;
// even 32nd notes at 200 BPM are ~37 ms apart.
constexpr chrono::milliseconds kChordWindow{30};

vector<Note> merge_near_simultaneous(vector<Note> notes) {
    stable_sort(notes.begin(), notes.end(), [](const Note& a, const Note& b) {
        return a.timestamp < b.timestamp;
    });
    vector<Note> merged;
    merged.reserve(notes.size());
    for (Note& note : notes) {
        if (!merged.empty() &&
            note.timestamp - merged.back().timestamp <= kChordWindow) {
            vector<Key>& chord = merged.back().keys;
            for (Key key : note.keys) {
                if (find(chord.begin(), chord.end(), key) == chord.end()) {
                    chord.push_back(key);
                }
            }
            continue;
        }
        merged.push_back(std::move(note));
    }
    return merged;
}

}  // namespace

vector<Note> GenshinSheetParser::translate() {
    if (is_midi_path(file_path)) {
        return merge_near_simultaneous(translate_midi());
    }
    json song = parse();
    if (metadata.type == Composed) {
        return merge_near_simultaneous(translate_composed(song));
    } else if (metadata.type == Recorded) {
        return merge_near_simultaneous(translate_recorded(song));
    }
    throw runtime_error("Invalid song type: " + to_string(metadata.type));
}

const SongMetadata& GenshinSheetParser::song_metadata() const {
    return metadata;
}
