#pragma once

#include <string>
#include <cstdint>
#include <vector>
#include <unordered_map>
#include <nlohmann/json.hpp>
#include "note.h"

using namespace std;
using json = nlohmann::json;

enum SongType {
    Composed,
    Recorded,
    Midi
};

struct MidiNote {
    uint8_t pitch = 0;
};

struct KeySignature {
    int8_t sharps_flats = 0;
    bool minor = false;
};

// Key-aware, octave-optimized MIDI transposition helpers. A signed shift is
// applied uniformly; unsupported pitches are never individually snapped.
char midi_to_key(uint8_t pitch);
bool is_lyre_playable_pitch(int pitch);
int calculate_base_transposition(const KeySignature& key_signature);
int calculate_transposition(const vector<MidiNote>& notes,
                            const KeySignature& key_signature);

// Returns false if one or more shifted pitches would leave MIDI's 0..127
// range.
bool transpose_notes(vector<MidiNote>& notes, int semitones);

struct SongMetadata {
    string title;
    int bpm = 0;
    SongType type;
};

struct ComposedNote {
    vector<int> note_index;
    int time;
};

struct RecordedNote {
    int note_index;
    int time;
};

class GenshinSheetParser {
private:
    string file_path;
    unordered_map<int, Key> index_map;
    SongMetadata metadata;
    vector<ComposedNote> parse_composed(json song);
    vector<RecordedNote> parse_recorded(json song);
public:
    GenshinSheetParser(string file);
    json parse();
    vector<Note> translate_composed(json song);
    vector<Note> translate_recorded(json song);
    vector<Note> translate_midi();
    vector<Note> translate();
    const SongMetadata& song_metadata() const;
};
