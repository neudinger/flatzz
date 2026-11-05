// Independent adapters for reading.fbs and graph.fbs using the official C++ API.
#include <flatbuffers/flatbuffers.h>
#include <cassert>
#include <fstream>
#include <iterator>
#include <vector>

// Explicit schema layout, with endian-aware values and initialized padding.
// These structs mirror what flatc generates; no host-native value memcpy.
struct alignas(4) Coordinates { float latitude, longitude; };
struct alignas(4) Location { Coordinates coordinates; float altitude; };
struct alignas(8) Sample {
  uint8_t flag, state;
  uint16_t count;
  uint32_t padding;
  uint64_t number;
};
struct alignas(8) Envelope {
  uint8_t leading, padding[7];
  Sample sample;
  double measure;
  uint16_t trailing;
  uint8_t tail_padding[6];
};
struct alignas(8) Matrix {
  uint8_t flags[3], states[2], padding[3];
  double values[3];
  Envelope envelopes[2];
};
static_assert(sizeof(Matrix) == 112 && offsetof(Matrix, values) == 8 &&
              offsetof(Matrix, envelopes) == 32);
struct ArrayPacket : private flatbuffers::Table {
  enum : flatbuffers::voffset_t { ENTRIES=4, MATRIX=6, EMPTY=8, BLOCKS=10 };
  const flatbuffers::Vector<const Envelope *> *entries() const {
    return GetPointer<const flatbuffers::Vector<const Envelope *> *>(ENTRIES);
  }
  const Matrix *matrix() const { return GetStruct<const Matrix *>(MATRIX); }
  const flatbuffers::Vector<const Sample *> *empty() const {
    return GetPointer<const flatbuffers::Vector<const Sample *> *>(EMPTY);
  }
  const flatbuffers::Vector<const Matrix *> *blocks() const {
    return GetPointer<const flatbuffers::Vector<const Matrix *> *>(BLOCKS);
  }
  bool Verify(flatbuffers::Verifier &verifier) const {
    return VerifyTableStart(verifier) && VerifyOffsetRequired(verifier, ENTRIES) &&
      verifier.VerifyVector(entries()) &&
      VerifyFieldRequired<Matrix>(verifier, MATRIX, alignof(Matrix)) &&
      VerifyOffset(verifier, EMPTY) && verifier.VerifyVector(empty()) &&
      VerifyOffset(verifier, BLOCKS) && verifier.VerifyVector(blocks()) &&
      verifier.EndTable();
  }
};
static_assert(sizeof(Location) == 12 && alignof(Location) == 4);
static_assert(sizeof(Sample) == 16 && offsetof(Sample, number) == 8);
static_assert(sizeof(Envelope) == 40 && offsetof(Envelope, sample) == 8 &&
              offsetof(Envelope, measure) == 24 && offsetof(Envelope, trailing) == 32);
struct Packet : private flatbuffers::Table {
  enum : flatbuffers::voffset_t { MARKER=4, ENVELOPE=6, EXTRA=8 };
  uint32_t marker() const { return GetField<uint32_t>(MARKER, 0); }
  const Envelope *envelope() const { return GetStruct<const Envelope *>(ENVELOPE); }
  const Sample *extra() const { return GetStruct<const Sample *>(EXTRA); }
  bool Verify(flatbuffers::Verifier &verifier) const {
    return VerifyTableStart(verifier) &&
      VerifyField<uint32_t>(verifier, MARKER, alignof(uint32_t)) &&
      VerifyFieldRequired<Envelope>(verifier, ENVELOPE, alignof(Envelope)) &&
      VerifyField<Sample>(verifier, EXTRA, alignof(Sample)) && verifier.EndTable();
  }
};
struct Reading : private flatbuffers::Table {
  enum : flatbuffers::voffset_t {
    SEQUENCE=4, VALUE=6, LABEL=8, ACTIVE=10, STATUS=12, SAMPLES=14,
    TEMPERATURE=16, TAGS=18, LOCATION=20
  };
  using Table::GetField;
  using Table::GetOptional;
  const Location *location() const { return GetStruct<const Location *>(LOCATION); }
  const flatbuffers::String *label() const { return GetPointer<const flatbuffers::String *>(LABEL); }
  const flatbuffers::Vector<float> *samples() const { return GetPointer<const flatbuffers::Vector<float> *>(SAMPLES); }
  const flatbuffers::Vector<flatbuffers::Offset<flatbuffers::String>> *tags() const {
    return GetPointer<const flatbuffers::Vector<flatbuffers::Offset<flatbuffers::String>> *>(TAGS);
  }
  bool Verify(flatbuffers::Verifier &verifier) const {
    return VerifyTableStart(verifier) &&
      VerifyField<uint32_t>(verifier, SEQUENCE, alignof(uint32_t)) &&
      VerifyField<float>(verifier, VALUE, alignof(float)) &&
      VerifyField<uint8_t>(verifier, ACTIVE, alignof(uint8_t)) &&
      VerifyField<uint8_t>(verifier, STATUS, alignof(uint8_t)) &&
      VerifyField<float>(verifier, TEMPERATURE, alignof(float)) &&
      VerifyField<Location>(verifier, LOCATION, alignof(Location)) &&
      VerifyOffset(verifier, LABEL) && verifier.VerifyString(label()) &&
      VerifyOffset(verifier, SAMPLES) && verifier.VerifyVector(samples()) &&
      VerifyOffset(verifier, TAGS) && verifier.VerifyVector(tags()) &&
      verifier.VerifyVectorOfStrings(tags()) && verifier.EndTable();
  }
};
struct Node : private flatbuffers::Table {
  enum : flatbuffers::voffset_t { NUMBER=4, NAME=6, NEXT=8 };
  uint64_t number() const { return GetField<uint64_t>(NUMBER, 0); }
  const flatbuffers::String *name() const { return GetPointer<const flatbuffers::String *>(NAME); }
  const Node *next() const { return GetPointer<const Node *>(NEXT); }
  bool Verify(flatbuffers::Verifier &verifier) const {
    return VerifyTableStart(verifier) && VerifyField<uint64_t>(verifier, NUMBER, alignof(uint64_t)) &&
      VerifyOffsetRequired(verifier, NAME) && verifier.VerifyString(name()) &&
      VerifyOffset(verifier, NEXT) && verifier.VerifyTable(next()) && verifier.EndTable();
  }
};
struct Graph : private flatbuffers::Table {
  enum : flatbuffers::voffset_t { REVISION=4, CHILD=6, CHILDREN=8, PAYLOAD=10 };
  uint16_t revision() const { return GetField<uint16_t>(REVISION, 0); }
  const Node *child() const { return GetPointer<const Node *>(CHILD); }
  const flatbuffers::Vector<flatbuffers::Offset<Node>> *children() const {
    return GetPointer<const flatbuffers::Vector<flatbuffers::Offset<Node>> *>(CHILDREN);
  }
  const flatbuffers::Vector<uint8_t> *payload() const { return GetPointer<const flatbuffers::Vector<uint8_t> *>(PAYLOAD); }
  bool Verify(flatbuffers::Verifier &verifier) const {
    return VerifyTableStart(verifier) && VerifyField<uint16_t>(verifier, REVISION, alignof(uint16_t)) &&
      VerifyOffsetRequired(verifier, CHILD) && verifier.VerifyTable(child()) &&
      VerifyOffset(verifier, CHILDREN) && verifier.VerifyVector(children()) &&
      verifier.VerifyVectorOfTables(children()) && VerifyOffset(verifier, PAYLOAD) &&
      verifier.VerifyVector(payload()) && verifier.EndTable();
  }
};
struct Event : private flatbuffers::Table {
  uint64_t number() const { return GetField<uint64_t>(4, 0); }
  const flatbuffers::String *name() const {
    return GetPointer<const flatbuffers::String *>(6);
  }
  bool Verify(flatbuffers::Verifier &verifier) const {
    return VerifyTableStart(verifier) && VerifyField<uint64_t>(verifier, 4, 8) &&
      VerifyOffsetRequired(verifier, 6) && verifier.VerifyString(name()) &&
      verifier.EndTable();
  }
};
struct UnionPacket : private flatbuffers::Table {
  using Values = flatbuffers::Vector<flatbuffers::Offset<void>>;
  enum : flatbuffers::voffset_t {
    CURRENT_TYPE=4, CURRENT=6, HISTORY_TYPE=8, HISTORY=10,
    REQUIRED_TYPE=12, REQUIRED=14, REQUIRED_HISTORY_TYPE=16,
    REQUIRED_HISTORY=18, MARKER=20
  };
  using Table::GetField;
  const void *value(flatbuffers::voffset_t slot) const {
    return GetPointer<const void *>(slot);
  }
  const flatbuffers::Vector<uint8_t> *types(flatbuffers::voffset_t slot) const {
    return GetPointer<const flatbuffers::Vector<uint8_t> *>(slot);
  }
  const Values *values(flatbuffers::voffset_t slot) const {
    return GetPointer<const Values *>(slot);
  }
  static bool verifyChoice(flatbuffers::Verifier &verifier, uint8_t tag,
                           const void *value) {
    if (!tag) return !value;
    if (!value) return false;
    switch (tag) {
    case 1: case 4: return verifier.VerifyTable(static_cast<const Event *>(value));
    case 2: return verifier.VerifyField<Envelope>(
      static_cast<const uint8_t *>(value), 0, alignof(Envelope));
    case 3: return verifier.VerifyString(static_cast<const flatbuffers::String *>(value));
    default: return false;
    }
  }
  static bool verifyChoices(flatbuffers::Verifier &verifier,
      const flatbuffers::Vector<uint8_t> *tags, const Values *payloads) {
    if (!tags || !payloads) return !tags && !payloads;
    if (!verifier.VerifyVector(tags) || !verifier.VerifyVector(payloads) ||
        tags->size() != payloads->size()) return false;
    for (flatbuffers::uoffset_t index = 0; index < tags->size(); ++index) {
      const auto *slot = payloads->Data() + index * sizeof(flatbuffers::uoffset_t);
      const auto offset = flatbuffers::ReadScalar<flatbuffers::uoffset_t>(slot);
      if (!tags->Get(index)) { if (offset) return false; continue; }
      if (!offset || !verifier.VerifyOffset<flatbuffers::uoffset_t>(slot, 0) ||
          !verifyChoice(verifier, tags->Get(index), payloads->Get(index))) return false;
    }
    return true;
  }
  bool Verify(flatbuffers::Verifier &verifier) const {
    return VerifyTableStart(verifier) &&
      VerifyField<uint8_t>(verifier, CURRENT_TYPE, 1) &&
      VerifyOffset(verifier, CURRENT) &&
      verifyChoice(verifier, GetField<uint8_t>(CURRENT_TYPE, 0), value(CURRENT)) &&
      VerifyOffset(verifier, HISTORY_TYPE) && VerifyOffset(verifier, HISTORY) &&
      verifyChoices(verifier, types(HISTORY_TYPE), values(HISTORY)) &&
      VerifyField<uint8_t>(verifier, REQUIRED_TYPE, 1) &&
      VerifyOffsetRequired(verifier, REQUIRED) &&
      verifyChoice(verifier, GetField<uint8_t>(REQUIRED_TYPE, 0), value(REQUIRED)) &&
      VerifyOffsetRequired(verifier, REQUIRED_HISTORY_TYPE) &&
      VerifyOffsetRequired(verifier, REQUIRED_HISTORY) &&
      verifyChoices(verifier, types(REQUIRED_HISTORY_TYPE), values(REQUIRED_HISTORY)) &&
      VerifyField<uint32_t>(verifier, MARKER, 4) && verifier.EndTable();
  }
};
static std::vector<uint8_t> load(const char *path) {
  std::ifstream input(path, std::ios::binary);
  assert(input);
  return {std::istreambuf_iterator<char>(input), {}};
}
static void save(const char *path, const flatbuffers::FlatBufferBuilder &builder) {
  std::ofstream output(path, std::ios::binary);
  output.write(reinterpret_cast<const char *>(builder.GetBufferPointer()), builder.GetSize());
  assert(output);
}
static flatbuffers::Offset<Node> node(flatbuffers::FlatBufferBuilder &builder,
    uint64_t number, const char *name, flatbuffers::Offset<Node> next = {}) {
  const auto label = builder.CreateString(name);
  const auto start = builder.StartTable();
  builder.AddElement<uint64_t>(Node::NUMBER, number, 0);
  builder.AddOffset(Node::NAME, label);
  builder.AddOffset(Node::NEXT, next);
  return flatbuffers::Offset<Node>(builder.EndTable(start));
}
int main() {
  const auto reading_bytes = load("zig-reading.bin");
  flatbuffers::Verifier reading_verifier(reading_bytes.data(), reading_bytes.size());
  assert(reading_verifier.VerifyBuffer<Reading>(nullptr));
  const auto *reading = flatbuffers::GetRoot<Reading>(reading_bytes.data());
  assert(reading->GetField<uint32_t>(Reading::SEQUENCE, 0) == 42);
  assert(reading->GetField<float>(Reading::VALUE, 0) == 1.5f);
  assert(reading->GetField<uint8_t>(Reading::ACTIVE, 0) == 1);
  assert(reading->GetField<uint8_t>(Reading::STATUS, 0) == 200);
  assert((reading->GetOptional<float, float>(Reading::TEMPERATURE).has_value()));
  assert((reading->GetOptional<float, float>(Reading::TEMPERATURE).value() == 0));
  assert(reading->label()->str() == "sensor");
  assert(reading->samples()->size() == 3 && reading->samples()->Get(2) == 2.5f);
  assert(reading->tags()->size() == 4 && reading->tags()->Get(2)->str() == "é");
  assert(reading->location());
  assert(flatbuffers::EndianScalar(reading->location()->coordinates.latitude) == 48.5f);
  assert(flatbuffers::EndianScalar(reading->location()->coordinates.longitude) == 2.25f);
  assert(flatbuffers::EndianScalar(reading->location()->altitude) == 35.0f);

  flatbuffers::FlatBufferBuilder builder;
  const auto label = builder.CreateString("sensor");
  const auto shared = builder.CreateString("one");
  const std::vector<flatbuffers::Offset<flatbuffers::String>> strings = {
    shared, builder.CreateString(""), builder.CreateString("é"), shared
  };
  const auto tags = builder.CreateVector(strings);
  const auto samples = builder.CreateVector(std::vector<float>{-1.5f, 0, 2.5f});
  const auto start = builder.StartTable();
  builder.AddElement<uint32_t>(Reading::SEQUENCE, 42, 0);
  builder.AddElement<float>(Reading::VALUE, 1.5f, 0);
  builder.AddOffset(Reading::LABEL, label);
  builder.AddElement<uint8_t>(Reading::ACTIVE, 1, 0);
  builder.AddElement<uint8_t>(Reading::STATUS, 200, 0);
  builder.AddOffset(Reading::SAMPLES, samples);
  builder.AddElement<float>(Reading::TEMPERATURE, 0); // Present optional zero.
  builder.AddOffset(Reading::TAGS, tags);
  const Location location{{flatbuffers::EndianScalar(48.5f),
                           flatbuffers::EndianScalar(2.25f)},
                          flatbuffers::EndianScalar(35.0f)};
  builder.AddStruct(Reading::LOCATION, &location);
  builder.Finish(flatbuffers::Offset<Reading>(builder.EndTable(start)));
  save("cpp-reading.bin", builder);
  const auto struct_bytes = load("zig-structs.bin");
  flatbuffers::Verifier struct_verifier(struct_bytes.data(), struct_bytes.size());
  assert(struct_verifier.VerifyBuffer<Packet>(nullptr));
  const auto *packet = flatbuffers::GetRoot<Packet>(struct_bytes.data());
  assert(packet->marker() == 42 && packet->envelope() && packet->extra());
  const auto *envelope = packet->envelope();
  assert(envelope->leading == 0x7f && envelope->sample.flag == 1 && envelope->sample.state == 200);
  assert(flatbuffers::EndianScalar(envelope->sample.count) == 0x2345);
  assert(flatbuffers::EndianScalar(envelope->sample.number) == UINT64_C(0x0102030405060708));
  assert(flatbuffers::EndianScalar(envelope->measure) == -12.5);
  assert(flatbuffers::EndianScalar(envelope->trailing) == 0x1234);
  assert(flatbuffers::EndianScalar(packet->extra()->number) == UINT64_C(0x0102030405060708));
  builder.Clear();
  const Sample sample{1, 200, flatbuffers::EndianScalar(uint16_t(0x2345)), 0,
                      flatbuffers::EndianScalar(UINT64_C(0x0102030405060708))};
  const Envelope replacement{0x7f, {}, sample, flatbuffers::EndianScalar(-12.5),
                             flatbuffers::EndianScalar(uint16_t(0x1234)), {}};
  const auto packet_start = builder.StartTable();
  builder.AddElement<uint32_t>(Packet::MARKER, 42, 0);
  builder.AddStruct(Packet::ENVELOPE, &replacement);
  builder.AddStruct(Packet::EXTRA, &sample);
  builder.Finish(flatbuffers::Offset<Packet>(builder.EndTable(packet_start)));
  save("cpp-structs.bin", builder);
  const auto array_bytes = load("zig-arrays.bin");
  flatbuffers::Verifier array_verifier(array_bytes.data(), array_bytes.size());
  assert(array_verifier.VerifyBuffer<ArrayPacket>(nullptr));
  const auto *arrays = flatbuffers::GetRoot<ArrayPacket>(array_bytes.data());
  assert(arrays->entries()->size() == 2);
  assert(flatbuffers::EndianScalar(arrays->entries()->Get(0)->measure) == -12.5);
  assert(flatbuffers::EndianScalar(arrays->entries()->Get(1)->measure) == 2.5);
  assert(arrays->empty() && arrays->empty()->size() == 0);
  assert(arrays->matrix()->flags[0] && !arrays->matrix()->flags[1]);
  assert(arrays->matrix()->states[0] == 200);
  assert(flatbuffers::EndianScalar(arrays->matrix()->values[2]) == 3.75);
  assert(arrays->matrix()->envelopes[1].leading == 9);
  assert(arrays->blocks()->size() == 1);
  assert(flatbuffers::EndianScalar(arrays->blocks()->Get(0)->values[1]) == -2.5);
  builder.Clear();
  const Envelope second{9, {}, sample, flatbuffers::EndianScalar(2.5),
                        flatbuffers::EndianScalar(uint16_t(7)), {}};
  const Matrix matrix{{1, 0, 1}, {200, 1}, {},
                       {flatbuffers::EndianScalar(1.5), flatbuffers::EndianScalar(-2.5),
                        flatbuffers::EndianScalar(3.75)}, {replacement, second}};
  const auto entries = builder.CreateVectorOfStructs(matrix.envelopes, 2);
  const auto empty_vector = builder.CreateVectorOfStructs<Sample>(nullptr, 0);
  const auto blocks = builder.CreateVectorOfStructs(&matrix, 1);
  const auto array_start = builder.StartTable();
  builder.AddOffset(ArrayPacket::ENTRIES, entries);
  builder.AddStruct(ArrayPacket::MATRIX, &matrix);
  builder.AddOffset(ArrayPacket::EMPTY, empty_vector);
  builder.AddOffset(ArrayPacket::BLOCKS, blocks);
  builder.Finish(flatbuffers::Offset<ArrayPacket>(builder.EndTable(array_start)));
  save("cpp-arrays.bin", builder);
  const auto union_bytes = load("zig-unions.bin");
  flatbuffers::Verifier union_verifier(union_bytes.data(), union_bytes.size());
  assert(union_verifier.VerifyBuffer<UnionPacket>(nullptr));
  const auto *unions = flatbuffers::GetRoot<UnionPacket>(union_bytes.data());
  assert(unions->GetField<uint32_t>(UnionPacket::MARKER, 0) == 42);
  assert(unions->GetField<uint8_t>(UnionPacket::CURRENT_TYPE, 0) == 1);
  const auto *event = static_cast<const Event *>(unions->value(UnionPacket::CURRENT));
  assert(event->number() == UINT64_C(0x0102030405060708));
  assert(event->name()->str() == "union");
  assert(unions->GetField<uint8_t>(UnionPacket::REQUIRED_TYPE, 0) == 2);
  const auto *union_envelope = static_cast<const Envelope *>(unions->value(UnionPacket::REQUIRED));
  assert(flatbuffers::EndianScalar(union_envelope->measure) == -12.5);
  const auto *history_types = unions->types(UnionPacket::HISTORY_TYPE);
  const auto *history_values = unions->values(UnionPacket::HISTORY);
  assert(history_types->size() == 5 && history_values->size() == 5);
  const std::vector<uint8_t> expected_tags{1, 0, 2, 3, 4};
  for (flatbuffers::uoffset_t index = 0; index < 5; ++index)
    assert(history_types->Get(index) == expected_tags[index]);
  assert(history_values->Get(0) == event && history_values->Get(4) == event);
  assert(history_values->Get(2) == union_envelope);
  assert(static_cast<const flatbuffers::String *>(history_values->Get(3))->str() == "union é");
  assert(unions->values(UnionPacket::REQUIRED_HISTORY)->size() == 0);
  builder.Clear();
  const auto event_name = builder.CreateString("union");
  const auto event_start = builder.StartTable();
  builder.AddElement<uint64_t>(4, UINT64_C(0x0102030405060708), 0);
  builder.AddOffset(6, event_name);
  const auto event_handle = flatbuffers::Offset<Event>(builder.EndTable(event_start));
  const auto envelope_handle = builder.CreateStruct(replacement);
  const auto text_handle = builder.CreateString("union é");
  builder.StartVector(5, sizeof(flatbuffers::uoffset_t), alignof(flatbuffers::uoffset_t));
  builder.PushElement(event_handle);
  builder.PushElement(text_handle);
  builder.PushElement(envelope_handle);
  // Offset<void>(0) is not a valid builder handle. NONE is a literal zero slot.
  builder.PushElement<flatbuffers::uoffset_t>(0);
  builder.PushElement(event_handle);
  const auto union_values = flatbuffers::Offset<UnionPacket::Values>(builder.EndVector(5));
  const auto union_tags = builder.CreateVector(expected_tags);
  const auto empty_tags = builder.CreateVector(std::vector<uint8_t>{});
  const auto empty_values = builder.CreateVector(std::vector<flatbuffers::Offset<void>>{});
  const auto union_start = builder.StartTable();
  builder.AddElement<uint8_t>(UnionPacket::CURRENT_TYPE, 1, 0);
  builder.AddOffset(UnionPacket::CURRENT, event_handle);
  builder.AddOffset(UnionPacket::HISTORY_TYPE, union_tags);
  builder.AddOffset(UnionPacket::HISTORY, union_values);
  builder.AddElement<uint8_t>(UnionPacket::REQUIRED_TYPE, 2, 0);
  builder.AddOffset(UnionPacket::REQUIRED, envelope_handle);
  builder.AddOffset(UnionPacket::REQUIRED_HISTORY_TYPE, empty_tags);
  builder.AddOffset(UnionPacket::REQUIRED_HISTORY, empty_values);
  builder.AddElement<uint32_t>(UnionPacket::MARKER, 42, 0);
  builder.Finish(flatbuffers::Offset<UnionPacket>(builder.EndTable(union_start)));
  save("cpp-unions.bin", builder);
  const struct Frame {
    const char *input, *output, *identifier;
    bool prefixed;
  } frames[] = {
    {"zig-graph.bin", "cpp-graph.bin", nullptr, false},
    {"zig-graph-prefixed.bin", "cpp-graph-prefixed.bin", nullptr, true},
    {"zig-graph-prefixed-id.bin", "cpp-graph-prefixed-id.bin", "GRPH", true},
  };
  for (const auto &frame : frames) {
    const auto graph_bytes = load(frame.input);
    flatbuffers::Verifier graph_verifier(graph_bytes.data(), graph_bytes.size());
    assert(frame.prefixed
      ? graph_verifier.VerifySizePrefixedBuffer<Graph>(frame.identifier)
      : graph_verifier.VerifyBuffer<Graph>(frame.identifier));
    const auto *graph = frame.prefixed
      ? flatbuffers::GetSizePrefixedRoot<Graph>(graph_bytes.data())
      : flatbuffers::GetRoot<Graph>(graph_bytes.data());
    assert(graph->revision() == 0x0201 && graph->child()->number() == 99);
    assert(graph->child()->name()->str() == "parent");
    assert(graph->child()->next()->number() == UINT64_C(0x0102030405060708));
    assert(graph->children()->Get(0) == graph->children()->Get(1));
    assert(graph->child()->next() == graph->children()->Get(0));
    assert(graph->payload()->Get(1) == 0xff);

    builder.Clear();
    const auto leaf = node(builder, UINT64_C(0x0102030405060708), "leaf");
    const auto parent = node(builder, 99, "parent", leaf);
    const auto children = builder.CreateVector(std::vector<flatbuffers::Offset<Node>>{leaf, leaf});
    const auto payload = builder.CreateVector(std::vector<uint8_t>{0, 0xff, 0x80, 7});
    const auto graph_start = builder.StartTable();
    builder.AddElement<uint16_t>(Graph::REVISION, 0x0201, 0);
    builder.AddOffset(Graph::CHILD, parent);
    builder.AddOffset(Graph::CHILDREN, children);
    builder.AddOffset(Graph::PAYLOAD, payload);
    const auto root = flatbuffers::Offset<Graph>(builder.EndTable(graph_start));
    if (frame.prefixed) builder.FinishSizePrefixed(root, frame.identifier);
    else builder.Finish(root, frame.identifier);
    save(frame.output, builder);
  }
}
