// Generated flatcc readers/verifiers/builders independently consume Zig output
// and clone it through the C construction implementation.
#include "reading_builder.h"
#include "reading_verifier.h"
#include "graph_builder.h"
#include "graph_verifier.h"
#include "structs_builder.h"
#include "structs_verifier.h"
#include "arrays_builder.h"
#include "arrays_verifier.h"
#include "unions_builder.h"
#include "unions_verifier.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void *load(const char *path, size_t *size) {
    FILE *input = fopen(path, "rb");
    assert(input);
    assert(!fseek(input, 0, SEEK_END));
    long length = ftell(input);
    assert(length >= 0);
    *size = (size_t)length;
    rewind(input);
    void *bytes = malloc(*size);
    assert(bytes && fread(bytes, 1, *size, input) == *size);
    fclose(input);
    return bytes;
}
static void save(const char *path, flatcc_builder_t *builder) {
    size_t size;
    void *bytes = flatcc_builder_finalize_buffer(builder, &size);
    assert(bytes);
    FILE *output = fopen(path, "wb");
    assert(output && fwrite(bytes, 1, size, output) == size);
    fclose(output);
    free(bytes);
}
int main(void) {
    size_t size;
    void *bytes = load("zig-reading.bin", &size);
    assert(!flatzz_test_Reading_verify_as_root(bytes, size));
    flatzz_test_Reading_table_t reading = flatzz_test_Reading_as_root(bytes);
    assert(flatzz_test_Reading_sequence(reading) == 42);
    assert(flatzz_test_Reading_status(reading) == 200);
    assert(flatzz_test_Reading_temperature_is_present(reading));
    assert(flatzz_test_Reading_temperature(reading) == 0);
    assert(!strcmp(flatzz_test_Reading_label(reading), "sensor"));
    assert(flatbuffers_string_vec_len(flatzz_test_Reading_tags(reading)) == 4);
    flatzz_test_Location_struct_t location = flatzz_test_Reading_location(reading);
    assert(location && flatzz_test_Location_altitude(location) == 35);
    flatzz_test_Coordinates_struct_t coordinates = flatzz_test_Location_coordinates(location);
    assert(flatzz_test_Coordinates_latitude(coordinates) == 48.5f);
    assert(flatzz_test_Coordinates_longitude(coordinates) == 2.25f);
    flatcc_builder_t builder;
    flatcc_builder_init(&builder);
    assert(flatzz_test_Reading_clone_as_root(&builder, reading));
    save("c-reading.bin", &builder);
    flatcc_builder_reset(&builder);
    free(bytes);
    bytes = load("zig-structs.bin", &size);
    assert(!flatzz_test_Packet_verify_as_root(bytes, size));
    flatzz_test_Packet_table_t packet = flatzz_test_Packet_as_root(bytes);
    assert(flatzz_test_Packet_marker(packet) == 42);
    flatzz_test_Envelope_struct_t envelope = flatzz_test_Packet_envelope(packet);
    assert(envelope && flatzz_test_Envelope_leading(envelope) == 0x7f);
    flatzz_test_Sample_struct_t sample = flatzz_test_Envelope_sample(envelope);
    assert(flatzz_test_Sample_flag(sample) && flatzz_test_Sample_state(sample) == 200);
    assert(flatzz_test_Sample_count(sample) == 0x2345);
    assert(flatzz_test_Sample_number(sample) == UINT64_C(0x0102030405060708));
    assert(flatzz_test_Envelope_measure(envelope) == -12.5);
    assert(flatzz_test_Envelope_trailing(envelope) == 0x1234);
    assert(flatzz_test_Sample_number(flatzz_test_Packet_extra(packet)) == UINT64_C(0x0102030405060708));
    assert(flatzz_test_Packet_clone_as_root(&builder, packet));
    save("c-structs.bin", &builder);
    flatcc_builder_reset(&builder);
    free(bytes);
    bytes = load("zig-arrays.bin", &size);
    assert(!flatzz_test_ArrayPacket_verify_as_root(bytes, size));
    flatzz_test_ArrayPacket_table_t arrays = flatzz_test_ArrayPacket_as_root(bytes);
    flatzz_test_Envelope_vec_t entries = flatzz_test_ArrayPacket_entries(arrays);
    assert(flatzz_test_Envelope_vec_len(entries) == 2);
    assert(flatzz_test_Envelope_measure(flatzz_test_Envelope_vec_at(entries, 0)) == -12.5);
    assert(flatzz_test_Envelope_measure(flatzz_test_Envelope_vec_at(entries, 1)) == 2.5);
    assert(flatzz_test_Sample_vec_len(flatzz_test_ArrayPacket_empty(arrays)) == 0);
    assert(flatzz_test_ArrayPacket_empty_is_present(arrays));
    flatzz_test_Matrix_struct_t matrix = flatzz_test_ArrayPacket_matrix(arrays);
    assert(flatzz_test_Matrix_flags(matrix, 0) && !flatzz_test_Matrix_flags(matrix, 1));
    assert(flatzz_test_Matrix_states(matrix, 0) == 200);
    assert(flatzz_test_Matrix_values(matrix, 2) == 3.75);
    assert(flatzz_test_Envelope_leading(flatzz_test_Matrix_envelopes(matrix, 1)) == 9);
    flatzz_test_Matrix_vec_t blocks = flatzz_test_ArrayPacket_blocks(arrays);
    assert(flatzz_test_Matrix_vec_len(blocks) == 1);
    assert(flatzz_test_Matrix_values(flatzz_test_Matrix_vec_at(blocks, 0), 1) == -2.5);
    assert(flatzz_test_ArrayPacket_clone_as_root(&builder, arrays));
    save("c-arrays.bin", &builder);
    flatcc_builder_reset(&builder);
    free(bytes);
    bytes = load("zig-unions.bin", &size);
    assert(!flatzz_test_UnionPacket_verify_as_root(bytes, size));
    flatzz_test_UnionPacket_table_t unions = flatzz_test_UnionPacket_as_root(bytes);
    assert(flatzz_test_UnionPacket_marker(unions) == 42);
    assert(flatzz_test_UnionPacket_current_type(unions) == flatzz_test_Payload_Event);
    flatzz_test_Event_table_t event = flatzz_test_UnionPacket_current(unions);
    assert(flatzz_test_Event_number(event) == UINT64_C(0x0102030405060708));
    assert(!strcmp(flatzz_test_Event_name(event), "union"));
    assert(flatzz_test_UnionPacket_required_value_type(unions) == flatzz_test_Payload_Envelope);
    envelope = flatzz_test_UnionPacket_required_value(unions);
    assert(flatzz_test_Envelope_measure(envelope) == -12.5);
    flatzz_test_Payload_union_vec_t history = flatzz_test_UnionPacket_history_union(unions);
    assert(flatzz_test_Payload_union_vec_len(history) == 5);
    const uint8_t expected_tags[] = {1, 0, 2, 3, 4};
    for (size_t index = 0; index < 5; ++index) {
        flatzz_test_Payload_union_t item = flatzz_test_Payload_union_vec_at(history, index);
        assert(item.type == expected_tags[index]);
        switch (item.type) {
        case flatzz_test_Payload_NONE: assert(item.value == NULL); break;
        case flatzz_test_Payload_Event:
        case flatzz_test_Payload_Again: assert(item.value == event); break;
        case flatzz_test_Payload_Envelope: assert(item.value == envelope); break;
        case flatzz_test_Payload_Text:
            assert(!strcmp(flatbuffers_string_cast_from_union(item), "union é"));
            break;
        default: assert(0);
        }
    }
    assert(flatzz_test_UnionPacket_required_history_is_present(unions));
    assert(flatzz_test_Payload_union_vec_len(flatzz_test_UnionPacket_required_history_union(unions)) == 0);
    // Explicit construction tests the C union builder, including NONE. The
    // pinned generated union-vector clone rejects null payload handles.
    assert(!flatbuffers_buffer_start(&builder, NULL));
    flatzz_test_Event_ref_t event_ref = flatzz_test_Event_clone(&builder, event);
    flatzz_test_Envelope_ref_t envelope_ref = flatzz_test_Envelope_clone(&builder, envelope);
    flatbuffers_string_ref_t text_ref = flatbuffers_string_create_str(&builder, "union é");
    assert(event_ref && envelope_ref && text_ref);
    const flatzz_test_Payload_union_ref_t union_values[] = {
        flatzz_test_Payload_as_Event(event_ref), flatzz_test_Payload_as_NONE(),
        flatzz_test_Payload_as_Envelope(envelope_ref), flatzz_test_Payload_as_Text(text_ref),
        flatzz_test_Payload_as_Again(event_ref)
    };
    flatzz_test_Payload_union_vec_ref_t history_ref = flatzz_test_Payload_vec_create(&builder, union_values, 5);
    flatzz_test_Payload_union_vec_ref_t empty_ref = flatzz_test_Payload_vec_create(&builder, NULL, 0);
    flatzz_test_UnionPacket_ref_t root_ref = flatzz_test_UnionPacket_create(&builder,
        flatzz_test_Payload_as_Event(event_ref), history_ref,
        flatzz_test_Payload_as_Envelope(envelope_ref), empty_ref, 42);
    assert(root_ref && flatbuffers_buffer_end(&builder, root_ref));
    save("c-unions.bin", &builder);
    flatcc_builder_reset(&builder);
    free(bytes);
    const struct Frame {
        const char *input, *output, *identifier;
        int prefixed;
    } frames[] = {
        {"zig-graph.bin", "c-graph.bin", NULL, 0},
        {"zig-graph-prefixed.bin", "c-graph-prefixed.bin", NULL, 1},
        {"zig-graph-prefixed-id.bin", "c-graph-prefixed-id.bin", "GRPH", 1},
    };
    for (size_t index = 0; index < sizeof(frames) / sizeof(frames[0]); ++index) {
        const struct Frame *frame = &frames[index];
        bytes = load(frame->input, &size);
        assert(!(frame->prefixed
            ? flatzz_test_Graph_verify_as_root_with_identifier_and_size(bytes, size, frame->identifier)
            : flatzz_test_Graph_verify_as_root_with_identifier(bytes, size, frame->identifier)));
        const void *buffer = frame->prefixed ? flatbuffers_read_size_prefix(bytes, NULL) : bytes;
        flatzz_test_Graph_table_t graph = flatzz_test_Graph_as_root_with_identifier(buffer, frame->identifier);
        flatzz_test_Node_table_t parent = flatzz_test_Graph_child(graph);
        flatzz_test_Node_table_t leaf = flatzz_test_Node_next(parent);
        assert(flatzz_test_Graph_revision(graph) == 0x0201);
        assert(flatzz_test_Node_number(parent) == 99);
        assert(flatzz_test_Node_number(leaf) == UINT64_C(0x0102030405060708));
        assert(leaf == flatzz_test_Node_vec_at(flatzz_test_Graph_children(graph), 0));
        assert(leaf == flatzz_test_Node_vec_at(flatzz_test_Graph_children(graph), 1));
        assert(flatbuffers_uint8_vec_at(flatzz_test_Graph_payload(graph), 1) == 0xff);
        assert(!flatcc_builder_start_buffer(&builder, frame->identifier, 0,
            frame->prefixed ? flatcc_builder_with_size : 0));
        assert(flatbuffers_buffer_end(&builder, flatzz_test_Graph_clone(&builder, graph)));
        save(frame->output, &builder);
        flatcc_builder_reset(&builder);
        free(bytes);
    }
    flatcc_builder_clear(&builder);
}
