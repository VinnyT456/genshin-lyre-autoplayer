#pragma once

#include <chrono>
#include <vector>
#include "key.h"

using namespace std;

struct Note {
    vector<Key> keys;
    chrono::milliseconds timestamp;

    Note(vector<Key> keys, chrono::milliseconds timestamp)
        : keys(keys), timestamp(timestamp) {}
};