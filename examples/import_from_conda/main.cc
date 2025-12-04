#include <archive.h>
#include <archive_entry.h>
#include <iostream>

int main() {
    // Create a new archive reader
    struct archive* a = archive_read_new();
    if (!a) {
        std::cerr << "Failed to create libarchive reader" << std::endl;
        return 1;
    }

    // Enable all decompression filters and formats
    archive_read_support_filter_all(a);
    archive_read_support_format_all(a);

    // Just open a non-existent file to prove linking works
    int r = archive_read_open_filename(a, "empty.tar", 10240);
    if (r != ARCHIVE_OK) {
        std::cerr << "Failed to open archive" << std::endl;
        return 1;
    }

    archive_read_free(a);
    return 0;
}
