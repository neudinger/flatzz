// Uses the local official Go runtime; no generated code or network dependency.
package main

import (
	"flatbuffers"
	"os"
)

func check(condition bool) {
	if !condition {
		panic("interoperability check failed")
	}
}
func load(path string) []byte {
	data, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	return data
}
func save(path string, builder *flatbuffers.Builder) {
	if err := os.WriteFile(path, builder.FinishedBytes(), 0600); err != nil {
		panic(err)
	}
}
func table(data []byte, position flatbuffers.UOffsetT) flatbuffers.Table {
	return flatbuffers.Table{Bytes: data, Pos: position}
}
func child(parent flatbuffers.Table, field flatbuffers.VOffsetT) flatbuffers.Table {
	return table(parent.Bytes, parent.Indirect(parent.Pos+flatbuffers.UOffsetT(parent.Offset(field))))
}
func node(builder *flatbuffers.Builder, number uint64, name string, next flatbuffers.UOffsetT) flatbuffers.UOffsetT {
	label := builder.CreateString(name)
	builder.StartObject(3)
	builder.PrependUint64Slot(0, number, 0)
	builder.PrependUOffsetTSlot(1, label, 0)
	builder.PrependUOffsetTSlot(2, next, 0)
	return builder.EndObject()
}

// Member writes follow the schema's reverse order, including explicit padding.
func sample(builder *flatbuffers.Builder) flatbuffers.UOffsetT {
	builder.Prep(8, 16)
	builder.PrependUint64(0x0102030405060708)
	builder.Pad(4)
	builder.PrependUint16(0x2345)
	builder.PrependUint8(200)
	builder.PrependBool(true)
	return builder.Offset()
}
func envelope(builder *flatbuffers.Builder) flatbuffers.UOffsetT {
	return envelopeValue(builder, 0x7f, -12.5, 0x1234)
}
func envelopeValue(builder *flatbuffers.Builder, leading uint8, measure float64, trailing uint16) flatbuffers.UOffsetT {
	builder.Prep(8, 40)
	builder.Pad(6)
	builder.PrependUint16(trailing)
	builder.PrependFloat64(measure)
	sample(builder)
	builder.Pad(7)
	builder.PrependUint8(leading)
	return builder.Offset()
}
func matrix(builder *flatbuffers.Builder) flatbuffers.UOffsetT {
	builder.Prep(8, 112)
	envelopeValue(builder, 9, 2.5, 7)
	envelope(builder)
	for _, value := range []float64{3.75, -2.5, 1.5} {
		builder.PrependFloat64(value)
	}
	builder.Pad(3)
	builder.PrependUint8(1)
	builder.PrependUint8(200)
	builder.PrependBool(true)
	builder.PrependBool(false)
	builder.PrependBool(true)
	return builder.Offset()
}
func main() {
	readingBytes := load("zig-reading.bin")
	reading := table(readingBytes, flatbuffers.GetUOffsetT(readingBytes))
	check(reading.GetUint32Slot(4, 0) == 42)
	check(reading.GetFloat32Slot(6, 0) == 1.5)
	check(reading.GetBoolSlot(10, false))
	check(reading.GetUint8Slot(12, 0) == 200)
	check(reading.Offset(16) != 0 && reading.GetFloat32Slot(16, 1) == 0)
	check(reading.String(reading.Pos+flatbuffers.UOffsetT(reading.Offset(8))) == "sensor")
	tagsOffset := reading.Offset(18)
	check(reading.VectorLen(flatbuffers.UOffsetT(tagsOffset)) == 4)
	tagsStart := reading.Vector(flatbuffers.UOffsetT(tagsOffset))
	check(reading.String(tagsStart+2*flatbuffers.SizeUOffsetT) == "é")
	check(reading.Offset(20) != 0)
	locationStart := reading.Pos + flatbuffers.UOffsetT(reading.Offset(20))
	check(reading.GetFloat32(locationStart) == 48.5)
	check(reading.GetFloat32(locationStart+4) == 2.25)
	check(reading.GetFloat32(locationStart+8) == 35)
	structBytes := load("zig-structs.bin")
	packet := table(structBytes, flatbuffers.GetUOffsetT(structBytes))
	check(packet.GetUint32Slot(4, 0) == 42 && packet.Offset(6) != 0)
	envelopeStart := packet.Pos + flatbuffers.UOffsetT(packet.Offset(6))
	check(packet.GetUint8(envelopeStart) == 0x7f)
	check(packet.GetBool(envelopeStart + 8))
	check(packet.GetUint8(envelopeStart+9) == 200)
	check(packet.GetUint16(envelopeStart+10) == 0x2345)
	check(packet.GetUint64(envelopeStart+16) == 0x0102030405060708)
	check(packet.GetFloat64(envelopeStart+24) == -12.5)
	check(packet.GetUint16(envelopeStart+32) == 0x1234)
	check(packet.Offset(8) != 0)
	extraStart := packet.Pos + flatbuffers.UOffsetT(packet.Offset(8))
	check(packet.GetUint64(extraStart+8) == 0x0102030405060708)
	arrayBytes := load("zig-arrays.bin")
	arrays := table(arrayBytes, flatbuffers.GetUOffsetT(arrayBytes))
	entriesStart := arrays.Vector(flatbuffers.UOffsetT(arrays.Offset(4)))
	check(arrays.VectorLen(flatbuffers.UOffsetT(arrays.Offset(4))) == 2)
	check(arrays.GetFloat64(entriesStart+24) == -12.5)
	check(arrays.GetFloat64(entriesStart+40+24) == 2.5)
	check(arrays.Offset(8) != 0 && arrays.VectorLen(flatbuffers.UOffsetT(arrays.Offset(8))) == 0)
	matrixStart := arrays.Pos + flatbuffers.UOffsetT(arrays.Offset(6))
	check(arrays.GetBool(matrixStart) && !arrays.GetBool(matrixStart+1))
	check(arrays.GetUint8(matrixStart+3) == 200)
	check(arrays.GetFloat64(matrixStart+24) == 3.75)
	check(arrays.GetUint8(matrixStart+32+40) == 9)
	blocksStart := arrays.Vector(flatbuffers.UOffsetT(arrays.Offset(10)))
	check(arrays.VectorLen(flatbuffers.UOffsetT(arrays.Offset(10))) == 1)
	check(arrays.GetFloat64(blocksStart+16) == -2.5)
	graphBytes := load("zig-graph.bin")
	graph := table(graphBytes, flatbuffers.GetUOffsetT(graphBytes))
	check(graph.GetUint16Slot(4, 0) == 0x0201)
	parent := child(graph, 6)
	leaf := child(parent, 8)
	check(parent.GetUint64Slot(4, 0) == 99)
	check(leaf.GetUint64Slot(4, 0) == 0x0102030405060708)
	childrenStart := graph.Vector(flatbuffers.UOffsetT(graph.Offset(8)))
	check(graph.Indirect(childrenStart) == leaf.Pos)
	check(graph.Indirect(childrenStart+flatbuffers.SizeUOffsetT) == leaf.Pos)
	check(graph.ByteVector(graph.Pos + flatbuffers.UOffsetT(graph.Offset(10)))[1] == 0xff)

	unionBytes := load("zig-unions.bin")
	unions := table(unionBytes, flatbuffers.GetUOffsetT(unionBytes))
	check(unions.GetUint32Slot(20, 0) == 42)
	check(unions.GetUint8Slot(4, 0) == 1)
	event := child(unions, 6)
	check(event.GetUint64Slot(4, 0) == 0x0102030405060708)
	check(event.String(event.Pos+flatbuffers.UOffsetT(event.Offset(6))) == "union")
	check(unions.GetUint8Slot(12, 0) == 2)
	unionEnvelope := unions.Indirect(unions.Pos + flatbuffers.UOffsetT(unions.Offset(14)))
	check(unions.GetFloat64(unionEnvelope+24) == -12.5)
	historyTypes := unions.Vector(flatbuffers.UOffsetT(unions.Offset(8)))
	historyValues := unions.Vector(flatbuffers.UOffsetT(unions.Offset(10)))
	check(unions.VectorLen(flatbuffers.UOffsetT(unions.Offset(8))) == 5)
	check(unions.VectorLen(flatbuffers.UOffsetT(unions.Offset(10))) == 5)
	for index, tag := range []byte{1, 0, 2, 3, 4} {
		check(unions.GetUint8(historyTypes+flatbuffers.UOffsetT(index)) == tag)
	}
	check(unions.Indirect(historyValues) == event.Pos)
	check(unions.GetUOffsetT(historyValues+4) == 0)
	check(unions.Indirect(historyValues+8) == unionEnvelope)
	check(unions.String(historyValues+12) == "union é")
	check(unions.Indirect(historyValues+16) == event.Pos)
	check(unions.Offset(16) != 0 && unions.Offset(18) != 0)
	check(unions.VectorLen(flatbuffers.UOffsetT(unions.Offset(16))) == 0)
	check(unions.VectorLen(flatbuffers.UOffsetT(unions.Offset(18))) == 0)

	builder := flatbuffers.NewBuilder(0)
	label := builder.CreateString("sensor")
	shared := builder.CreateString("one")
	empty := builder.CreateString("")
	accent := builder.CreateString("é")
	builder.StartVector(flatbuffers.SizeUOffsetT, 4, flatbuffers.SizeUOffsetT)
	for _, value := range []flatbuffers.UOffsetT{shared, accent, empty, shared} {
		builder.PrependUOffsetT(value)
	}
	tags := builder.EndVector(4)
	builder.StartVector(flatbuffers.SizeFloat32, 3, flatbuffers.SizeFloat32)
	for _, value := range []float32{2.5, 0, -1.5} {
		builder.PrependFloat32(value)
	}
	samples := builder.EndVector(3)
	builder.StartObject(9)
	builder.PrependUint32Slot(0, 42, 0)
	builder.PrependFloat32Slot(1, 1.5, 0)
	builder.PrependUOffsetTSlot(2, label, 0)
	builder.PrependBoolSlot(3, true, false)
	builder.PrependUint8Slot(4, 200, 0)
	builder.PrependUOffsetTSlot(5, samples, 0)
	builder.PrependFloat32(0) // Store optional zero without default omission.
	builder.Slot(6)
	builder.PrependUOffsetTSlot(7, tags, 0)
	builder.Prep(4, 12)
	builder.PrependFloat32(35)
	builder.PrependFloat32(2.25)
	builder.PrependFloat32(48.5)
	builder.PrependStructSlot(8, builder.Offset(), 0)
	builder.Finish(builder.EndObject())
	save("go-reading.bin", builder)
	builder.Reset()
	builder.StartObject(3)
	builder.PrependUint32Slot(0, 42, 0)
	envelopePosition := envelope(builder)
	builder.PrependStructSlot(1, envelopePosition, 0)
	samplePosition := sample(builder)
	builder.PrependStructSlot(2, samplePosition, 0)
	builder.Finish(builder.EndObject())
	save("go-structs.bin", builder)
	builder.Reset()
	builder.StartVector(40, 2, 8)
	envelopeValue(builder, 9, 2.5, 7)
	envelope(builder)
	entries := builder.EndVector(2)
	builder.StartVector(16, 0, 8)
	emptyVector := builder.EndVector(0)
	builder.StartVector(112, 1, 8)
	matrix(builder)
	blocks := builder.EndVector(1)
	builder.StartObject(4)
	builder.PrependUOffsetTSlot(0, entries, 0)
	matrixPosition := matrix(builder)
	builder.PrependStructSlot(1, matrixPosition, 0)
	builder.PrependUOffsetTSlot(2, emptyVector, 0)
	builder.PrependUOffsetTSlot(3, blocks, 0)
	builder.Finish(builder.EndObject())
	save("go-arrays.bin", builder)
	builder.Reset()
	leafHandle := node(builder, 0x0102030405060708, "leaf", 0)
	parentHandle := node(builder, 99, "parent", leafHandle)
	builder.StartVector(flatbuffers.SizeUOffsetT, 2, flatbuffers.SizeUOffsetT)
	builder.PrependUOffsetT(leafHandle)
	builder.PrependUOffsetT(leafHandle)
	children := builder.EndVector(2)
	payload := builder.CreateByteVector([]byte{0, 0xff, 0x80, 7})
	builder.StartObject(4)
	builder.PrependUint16Slot(0, 0x0201, 0)
	builder.PrependUOffsetTSlot(1, parentHandle, 0)
	builder.PrependUOffsetTSlot(2, children, 0)
	builder.PrependUOffsetTSlot(3, payload, 0)
	builder.Finish(builder.EndObject())
	save("go-graph.bin", builder)
	builder.Reset()
	eventName := builder.CreateString("union")
	builder.StartObject(2)
	builder.PrependUint64Slot(0, 0x0102030405060708, 0)
	builder.PrependUOffsetTSlot(1, eventName, 0)
	eventHandle := builder.EndObject()
	envelopeHandle := envelope(builder)
	textHandle := builder.CreateString("union é")
	builder.StartVector(flatbuffers.SizeUOffsetT, 5, flatbuffers.SizeUOffsetT)
	for _, handle := range []flatbuffers.UOffsetT{eventHandle, textHandle, envelopeHandle, 0, eventHandle} {
		if handle == 0 {
			builder.PrependUint32(0) // NONE: literal zero, never a relative offset.
		} else {
			builder.PrependUOffsetT(handle)
		}
	}
	unionValues := builder.EndVector(5)
	unionTags := builder.CreateByteVector([]byte{1, 0, 2, 3, 4})
	unionEmptyTags := builder.CreateByteVector([]byte{})
	builder.StartVector(flatbuffers.SizeUOffsetT, 0, flatbuffers.SizeUOffsetT)
	unionEmptyValues := builder.EndVector(0)
	builder.StartObject(9)
	builder.PrependUint8Slot(0, 1, 0)
	builder.PrependUOffsetTSlot(1, eventHandle, 0)
	builder.PrependUOffsetTSlot(2, unionTags, 0)
	builder.PrependUOffsetTSlot(3, unionValues, 0)
	builder.PrependUint8Slot(4, 2, 0)
	builder.PrependUOffsetTSlot(5, envelopeHandle, 0)
	builder.PrependUOffsetTSlot(6, unionEmptyTags, 0)
	builder.PrependUOffsetTSlot(7, unionEmptyValues, 0)
	builder.PrependUint32Slot(8, 42, 0)
	builder.Finish(builder.EndObject())
	save("go-unions.bin", builder)
}
