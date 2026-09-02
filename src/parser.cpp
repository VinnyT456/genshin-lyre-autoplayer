#include <string>
#include <vector>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <cmath>
#include "parser.h"

using namespace std;


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
    metadata.bpm = 60000 / song[0].value("bpm", 0) ;
    metadata.type = song[0].value("type", "composed") == "composed" ? Composed : Recorded;

    return song;
}

vector<ComposedNote> GenshinSheetParser::parse_composed(json song) {
    const double ms_per_beat = metadata.bpm;
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
            keys.push_back(index_map.at(index));
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

vector<Note> GenshinSheetParser::translate() {
    json song = parse();
    if (metadata.type == Composed) {
        return translate_composed(song);
    } else if (metadata.type == Recorded) {
        return translate_recorded(song);
    }
    throw runtime_error("Invalid song type: " + to_string(metadata.type));
}

const SongMetadata& GenshinSheetParser::song_metadata() const {
    return metadata;
}