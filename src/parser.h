#pragma once

#include <string>
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