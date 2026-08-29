#pragma once

#include <string>
#include <vector>
#include <unordered_map>
#include "note.h"

using namespace std;

struct SongMetadata {
    string title;
    int bpm = 0;
};

struct RecordedNote {
    int note_index;
    int time;
    string layer;
};

class GenshinSheetParser {
private:
    string file_path;
    unordered_map<int, Key> index_map;
    SongMetadata metadata;
public:
    GenshinSheetParser(string file);
    vector<RecordedNote> parse();
    vector<Note> translate();
    const SongMetadata& song_metadata() const;
};