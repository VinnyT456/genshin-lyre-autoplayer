#include <string>
#include <vector>
#include <fstream>
#include <nlohmann/json.hpp>
#include <iostream>
#include <stdexcept>

#include "parser.h"

using namespace std;
using json = nlohmann::json;

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

vector<RecordedNote> GenshinSheetParser::parse() {
    ifstream file(file_path);
    if (!file.is_open()) {
        throw runtime_error("Unable to open sheet: " + file_path);
    }

    json song;
    file >> song;

    if (!song.is_array() || song.empty() || !song[0].contains("notes")) {
        throw runtime_error("Invalid .genshinsheet document");
    }

    metadata.title = song[0].value("name", "Untitled");
    metadata.bpm = song[0].value("bpm", 0);

    vector<RecordedNote> song_notes;
    for (auto note : song[0]["notes"]) {
        song_notes.push_back(RecordedNote{
            note[0],
            note[1],
            note[2]
        });
    }
    return song_notes;
}

vector<Note> GenshinSheetParser::translate() {
    vector<RecordedNote> song_notes = parse();
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

        keys.push_back(
            index_map.at(note.note_index)
        );
    }

    if (!keys.empty()) {
        result.emplace_back(
            keys,
            chrono::milliseconds(currentTime)
        );
    }

    return result;
}

const SongMetadata& GenshinSheetParser::song_metadata() const {
    return metadata;
}