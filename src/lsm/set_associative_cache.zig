const std = @import("std");
const builtin = @import("builtin");

const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const meta = std.meta;
const Vector = meta.Vector;

const verify = @import("tree.zig").verify;

pub const Layout = struct {
    ways: u64 = 16,
    tag_bits: u64 = 8,
    clock_bits: u64 = 2,
    cache_line_size: u64 = 64,
    /// Set this to a non-null value to override the alignment of the stored values.
    value_alignment: ?u29 = null,
};

pub fn SetAssociativeCache(
    comptime Key: type,
    comptime Value: type,
    comptime key_from_value: fn (Value) callconv(.Inline) Key,
    comptime hash: fn (Key) callconv(.Inline) u64,
    comptime equal: fn (Key, Key) callconv(.Inline) bool,
    comptime layout: Layout,
) type {
    assert(math.isPowerOfTwo(@sizeOf(Key)));
    assert(math.isPowerOfTwo(@sizeOf(Value)));

    switch (layout.ways) {
        // An 8-way set-associative cache has the clock hand as a u3, which would introduce padding.
        2, 4, 16 => {},
        else => @compileError("ways must be 2, 4 or 16 for optimal CLOCK hand size."),
    }
    switch (layout.tag_bits) {
        8, 16 => {},
        else => @compileError("tag_bits must be 8 or 16."),
    }
    switch (layout.clock_bits) {
        1, 2, 4 => {},
        else => @compileError("clock_bits must be 1, 2 or 4."),
    }

    if (layout.value_alignment) |alignment| {
        assert(alignment > @alignOf(Value));
        assert(@sizeOf(Value) % alignment == 0);
    }
    const value_alignment = layout.value_alignment orelse @alignOf(Value);

    assert(math.isPowerOfTwo(layout.ways));
    assert(math.isPowerOfTwo(layout.tag_bits));
    assert(math.isPowerOfTwo(layout.clock_bits));
    assert(math.isPowerOfTwo(layout.cache_line_size));

    assert(@sizeOf(Key) <= @sizeOf(Value));
    assert(@sizeOf(Key) < layout.cache_line_size);
    assert(layout.cache_line_size % @sizeOf(Key) == 0);

    if (layout.cache_line_size > @sizeOf(Value)) {
        assert(layout.cache_line_size % @sizeOf(Value) == 0);
    } else {
        assert(@sizeOf(Value) % layout.cache_line_size == 0);
    }

    const clock_hand_bits = math.log2_int(u64, layout.ways);
    assert(math.isPowerOfTwo(clock_hand_bits));
    assert((1 << clock_hand_bits) == layout.ways);

    const tags_per_line = @divExact(layout.cache_line_size * 8, layout.ways * layout.tag_bits);
    assert(tags_per_line > 0);

    const clocks_per_line = @divExact(layout.cache_line_size * 8, layout.ways * layout.clock_bits);
    assert(clocks_per_line > 0);

    const clock_hands_per_line = @divExact(layout.cache_line_size * 8, clock_hand_bits);
    assert(clock_hands_per_line > 0);

    const Tag = meta.Int(.unsigned, layout.tag_bits);
    const Count = meta.Int(.unsigned, layout.clock_bits);
    const Clock = meta.Int(.unsigned, clock_hand_bits);

    return struct {
        const Self = @This();

        sets: u64,
        tags: []Tag,
        values: []align(value_alignment) Value,
        counts: PackedUnsignedIntegerArray(Count),
        clocks: PackedUnsignedIntegerArray(Clock),

        pub fn init(allocator: mem.Allocator, value_count_max: u64) !Self {
            assert(math.isPowerOfTwo(value_count_max));
            assert(value_count_max > 0);
            assert(value_count_max >= layout.ways);
            assert(value_count_max % layout.ways == 0);

            const sets = @divExact(value_count_max, layout.ways);
            assert(math.isPowerOfTwo(sets));

            const value_size_max = value_count_max * @sizeOf(Value);
            assert(value_size_max >= layout.cache_line_size);
            assert(value_size_max % layout.cache_line_size == 0);

            const counts_size = @divExact(value_count_max * layout.clock_bits, 8);
            assert(counts_size >= layout.cache_line_size);
            assert(counts_size % layout.cache_line_size == 0);

            const clocks_size = @divExact(sets * clock_hand_bits, 8);
            assert(clocks_size >= layout.cache_line_size);
            assert(clocks_size % layout.cache_line_size == 0);

            const tags = try allocator.alloc(Tag, value_count_max);
            errdefer allocator.free(tags);

            const values = try allocator.allocAdvanced(
                Value,
                value_alignment,
                value_count_max,
                .exact,
            );
            errdefer allocator.free(values);

            const counts = try allocator.alloc(u64, @divExact(counts_size, @sizeOf(u64)));
            errdefer allocator.free(counts);

            const clocks = try allocator.alloc(u64, @divExact(clocks_size, @sizeOf(u64)));
            errdefer allocator.free(clocks);

            var self = Self{
                .sets = sets,
                .tags = tags,
                .values = values,
                .counts = .{ .words = counts },
                .clocks = .{ .words = clocks },
            };

            self.reset();

            return self;
        }

        pub fn deinit(self: *Self, allocator: mem.Allocator) void {
            assert(self.sets > 0);
            self.sets = 0;

            allocator.free(self.tags);
            allocator.free(self.values);
            allocator.free(self.counts.words);
            allocator.free(self.clocks.words);
        }

        pub fn reset(self: *Self) void {
            mem.set(Tag, self.tags, 0);
            mem.set(u64, self.counts.words, 0);
            mem.set(u64, self.clocks.words, 0);
        }

        pub fn get(self: *Self, key: Key) ?*align(value_alignment) Value {
            const set = self.associate(key);
            const way = self.search(set, key) orelse return null;

            const count = self.counts.get(set.offset + way);
            self.counts.set(set.offset + way, count +| 1);

            return @alignCast(value_alignment, &set.values[way]);
        }

        /// Remove a key from the set associative cache if present.
        pub fn remove(self: *Self, key: Key) void {
            const set = self.associate(key);
            const way = self.search(set, key) orelse return;

            self.counts.set(set.offset + way, 0);
        }

        /// If the key is present in the set, returns the way. Otherwise returns null.
        inline fn search(self: *Self, set: Set, key: Key) ?usize {
            const matches = matches_bitmask(set.tags, set.tag);
            var it = BitMaskIter(MatchesBitmask){ .mask = matches };
            while (it.next()) |way| {
                const count = self.counts.get(set.offset + way);
                if (count > 0 and equal(key_from_value(set.values[way]), key)) {
                    return way;
                }
            }
            return null;
        }

        const MatchesBitmask = meta.Int(.unsigned, layout.ways);
        inline fn matches_bitmask(tags: *[layout.ways]Tag, tag: Tag) MatchesBitmask {
            const tags_vec: Vector(layout.ways, Tag) = tags.*;
            const matches = @splat(layout.ways, tag) == tags_vec;
            return @ptrCast(*const MatchesBitmask, &matches).*;
        }

        pub fn put_no_clobber(self: *Self, key: Key) *align(value_alignment) Value {
            return self.put_no_clobber_preserve_locked(
                void,
                struct {
                    inline fn locked(_: void, _: *const Value) bool {
                        return false;
                    }
                }.locked,
                {},
                key,
            );
        }

        /// Add a key, evicting older entires if needed, and return a pointer to the value.
        /// The key must not already be in the cache.
        /// Never evicts keys for which locked() returns true.
        /// The caller must guarantee that locked() returns true for less than layout.ways keys.
        pub fn put_no_clobber_preserve_locked(
            self: *Self,
            comptime Context: type,
            comptime locked: fn (Context, *align(value_alignment) const Value) callconv(.Inline) bool,
            context: Context,
            key: Key,
        ) *align(value_alignment) Value {
            const set = self.associate(key);

            if (verify) {
                assert(self.search(set, key) == null);
            }

            const clock_index = @divExact(set.offset, layout.ways);

            const clock_iterations_max = layout.ways * math.maxInt(Count);
            var safety_count: usize = 1;

            var way = self.clocks.get(clock_index);
            comptime assert(math.maxInt(@TypeOf(way)) == layout.ways - 1);
            comptime assert(@as(@TypeOf(way), math.maxInt(@TypeOf(way))) +% 1 == 0);

            while (safety_count <= clock_iterations_max + 1) : ({
                way +%= 1;
                safety_count += 1;
            }) {
                // We pass a value pointer to the callback here so that a cache miss
                // can be avoided if the caller is able to determine if the value is
                // locked by comparing pointers directly.
                if (locked(context, @alignCast(value_alignment, &set.values[way]))) continue;

                var count = self.counts.get(set.offset + way);

                // Free way found
                if (count == 0) break;

                count -= 1;
                self.counts.set(set.offset + way, count);

                // This way is now free
                if (count == 0) break;
            }
            assert(safety_count <= clock_iterations_max);

            self.clocks.set(clock_index, way +% 1);

            set.tags[way] = set.tag;

            self.counts.set(set.offset + way, 1);

            return @alignCast(value_alignment, &set.values[way]);
        }

        const Set = struct {
            tag: Tag,
            offset: u64,
            tags: *[layout.ways]Tag,
            values: *[layout.ways]Value,

            fn inspect(set: Set, sac: Self) void {
                const clock_index = @divExact(set.offset, layout.ways);
                std.debug.print(
                    \\{{
                    \\  tag={}
                    \\  offset={}
                    \\  clock_hand={}
                , .{
                    set.tag,
                    set.offset,
                    sac.clocks.get(clock_index),
                });
                std.debug.print("\n  tags={}", .{set.tags[0]});
                for (set.tags[1..]) |tag| std.debug.print(", {}", .{tag});
                std.debug.print("\n  values={}", .{set.values[0]});
                for (set.values[1..]) |value| std.debug.print(", {}", .{value});
                std.debug.print("\n  counts={}", .{sac.counts.get(set.offset)});
                var i: usize = 1;
                while (i < layout.ways) : (i += 1) {
                    std.debug.print(", {}", .{sac.counts.get(set.offset + i)});
                }
                std.debug.print("\n}}\n", .{});
            }
        };

        inline fn associate(self: *Self, key: Key) Set {
            const entropy = hash(key);

            const tag = @truncate(Tag, entropy >> math.log2_int(u64, self.sets));
            const index = entropy % self.sets;
            const offset = index * layout.ways;

            return .{
                .tag = tag,
                .offset = offset,
                .tags = self.tags[offset..][0..layout.ways],
                .values = self.values[offset..][0..layout.ways],
            };
        }

        pub fn inspect() void {
            std.debug.print("Key={} Value={} ways={} tag_bits={} clock_bits={} clock_hand_bits={} tags_per_line={} clocks_per_line={} clock_hands_per_line={}\n", .{
                @bitSizeOf(Key),
                @sizeOf(Value),
                layout.ways,
                layout.tag_bits,
                layout.clock_bits,
                clock_hand_bits,
                tags_per_line,
                clocks_per_line,
                clock_hands_per_line,
            });
        }
    };
}

test "SetAssociativeCache: eviction" {
    const testing = std.testing;

    const log = false;

    const Key = u64;
    const Value = u64;

    const context = struct {
        inline fn key_from_value(value: Value) Key {
            return value;
        }
        inline fn hash(key: Key) u64 {
            return key;
        }
        inline fn equal(a: Key, b: Key) bool {
            return a == b;
        }
    };

    const layout: Layout = .{};
    const SAC = SetAssociativeCache(
        Key,
        Value,
        context.key_from_value,
        context.hash,
        context.equal,
        layout,
    );
    if (log) SAC.inspect();

    // TODO Add a nice calculator method to help solve the minimum value_count_max required:
    var sac = try SAC.init(std.testing.allocator, 16 * 16 * 8);
    defer sac.deinit(std.testing.allocator);

    try testing.expectEqual(@as(?*Value, null), sac.get(123));
    const value_ptr = sac.put_no_clobber(123);
    value_ptr.* = 123;
    try testing.expectEqual(@as(Value, 123), sac.get(123).?.*);

    // Fill up the first set entirely.
    {
        var i: usize = 0;
        while (i < layout.ways) : (i += 1) {
            try testing.expectEqual(i, sac.clocks.get(0));

            const key = i * sac.sets;
            sac.put_no_clobber(key).* = key;
            try testing.expect(sac.counts.get(i) == 1);
            try testing.expectEqual(key, sac.get(key).?.*);
            try testing.expect(sac.counts.get(i) == 2);
        }
        try testing.expect(sac.clocks.get(0) == 0);
    }

    if (log) sac.associate(0).inspect(sac);

    // insert another element into the first set, causing key 0 to be evicted
    {
        const key = layout.ways * sac.sets;
        sac.put_no_clobber(key).* = key;
        try testing.expect(sac.counts.get(0) == 1);
        try testing.expectEqual(key, sac.get(key).?.*);
        try testing.expect(sac.counts.get(0) == 2);

        try testing.expectEqual(@as(?*Value, null), sac.get(0));

        {
            var i: usize = 1;
            while (i < layout.ways) : (i += 1) {
                try testing.expect(sac.counts.get(i) == 1);
            }
        }
    }

    if (log) sac.associate(0).inspect(sac);

    // lock all other slots, causing key layout.ways * sac.sets to be evicted despite having the
    // highest count.
    {
        {
            assert(sac.counts.get(0) == 2);
            var i: usize = 1;
            while (i < layout.ways) : (i += 1) assert(sac.counts.get(i) == 1);
        }

        const key = (layout.ways + 1) * sac.sets;

        const expect_evicted = layout.ways * sac.sets;

        sac.put_no_clobber_preserve_locked(
            u64,
            struct {
                inline fn locked(only_unlocked: u64, value: *const Value) bool {
                    return value.* != only_unlocked;
                }
            }.locked,
            expect_evicted,
            key,
        ).* = key;

        try testing.expectEqual(@as(?*Value, null), sac.get(expect_evicted));
    }

    if (log) sac.associate(0).inspect(sac);

    // Ensure removal works
    {
        const key = 5 * sac.sets;
        assert(sac.get(key).?.* == key);
        try testing.expect(sac.counts.get(5) == 2);

        sac.remove(key);
        try testing.expectEqual(@as(?*Value, null), sac.get(key));
        try testing.expect(sac.counts.get(5) == 0);
    }
}

/// A little simpler than PackedIntArray in the std lib, restricted to little endian 64-bit words,
/// and using words exactly without padding.
fn PackedUnsignedIntegerArray(comptime UInt: type) type {
    const Word = u64;

    assert(builtin.target.cpu.arch.endian() == .Little);
    assert(@typeInfo(UInt).Int.signedness == .unsigned);
    assert(@typeInfo(UInt).Int.bits < meta.bitCount(u8));
    assert(math.isPowerOfTwo(@typeInfo(UInt).Int.bits));

    const word_bits = meta.bitCount(Word);
    const uint_bits = meta.bitCount(UInt);
    const uints_per_word = @divExact(word_bits, uint_bits);

    // An index bounded by the number of unsigned integers that fit exactly into a word.
    const WordIndex = meta.Int(.unsigned, math.log2_int(u64, uints_per_word));
    assert(math.maxInt(WordIndex) == uints_per_word - 1);

    // An index bounded by the number of bits (not unsigned integers) that fit exactly into a word.
    const BitsIndex = math.Log2Int(Word);
    assert(math.maxInt(BitsIndex) == meta.bitCount(Word) - 1);
    assert(math.maxInt(BitsIndex) == word_bits - 1);
    assert(math.maxInt(BitsIndex) == uint_bits * (math.maxInt(WordIndex) + 1) - 1);

    return struct {
        const Self = @This();

        words: []Word,

        /// Returns the unsigned integer at `index`.
        pub inline fn get(self: Self, index: u64) UInt {
            // This truncate is safe since we want to mask the right-shifted word by exactly a UInt:
            return @truncate(UInt, self.word(index).* >> bits_index(index));
        }

        /// Sets the unsigned integer at `index` to `value`.
        pub inline fn set(self: Self, index: u64, value: UInt) void {
            const w = self.word(index);
            w.* &= ~mask(index);
            w.* |= @as(Word, value) << bits_index(index);
        }

        inline fn mask(index: u64) Word {
            return @as(Word, math.maxInt(UInt)) << bits_index(index);
        }

        inline fn word(self: Self, index: u64) *Word {
            return &self.words[@divFloor(index, uints_per_word)];
        }

        inline fn bits_index(index: u64) BitsIndex {
            // If uint_bits=2, then it's normal for the maximum return value value to be 62, even
            // where BitsIndex allows up to 63 (inclusive) for a 64-bit word. This is because 62 is
            // the bit index of the highest 2-bit UInt (e.g. bit index + bit length == 64).
            comptime assert(uint_bits * (math.maxInt(WordIndex) + 1) == math.maxInt(BitsIndex) + 1);

            return @as(BitsIndex, uint_bits) * @truncate(WordIndex, index);
        }
    };
}

fn ArrayTestContext(comptime UInt: type) type {
    const testing = std.testing;
    return struct {
        const Self = @This();

        const Array = PackedUnsignedIntegerArray(UInt);
        random: std.rand.Random,

        array: Array,
        reference: []UInt,

        fn init(random: std.rand.Random, len: usize) !Self {
            const words = try testing.allocator.alloc(u64, @divExact(len * @bitSizeOf(UInt), 64));
            errdefer testing.allocator.free(words);

            const reference = try testing.allocator.alloc(UInt, len);
            errdefer testing.allocator.free(reference);

            mem.set(u64, words, 0);
            mem.set(UInt, reference, 0);

            return Self{
                .random = random,
                .array = Array{ .words = words },
                .reference = reference,
            };
        }

        fn deinit(context: *Self) void {
            testing.allocator.free(context.array.words);
            testing.allocator.free(context.reference);
        }

        fn run(context: *Self) !void {
            var iterations: usize = 0;
            while (iterations < 10_000) : (iterations += 1) {
                const index = context.random.uintLessThanBiased(usize, context.reference.len);
                const value = context.random.int(UInt);

                context.array.set(index, value);
                context.reference[index] = value;

                try context.verify();
            }
        }

        fn verify(context: *Self) !void {
            for (context.reference) |value, index| {
                try testing.expectEqual(value, context.array.get(index));
            }
        }
    };
}

test "PackedUnsignedIntegerArray: unit" {
    const testing = std.testing;

    var words = [8]u64{ 0, 0b10110010, 0, 0, 0, 0, 0, 0 };

    var p: PackedUnsignedIntegerArray(u2) = .{
        .words = &words,
    };

    try testing.expectEqual(@as(u2, 0b10), p.get(32 + 0));
    try testing.expectEqual(@as(u2, 0b00), p.get(32 + 1));
    try testing.expectEqual(@as(u2, 0b11), p.get(32 + 2));
    try testing.expectEqual(@as(u2, 0b10), p.get(32 + 3));

    p.set(0, 0b01);
    try testing.expectEqual(@as(u64, 0b00000001), words[0]);
    try testing.expectEqual(@as(u2, 0b01), p.get(0));
    p.set(1, 0b10);
    try testing.expectEqual(@as(u64, 0b00001001), words[0]);
    try testing.expectEqual(@as(u2, 0b10), p.get(1));
    p.set(2, 0b11);
    try testing.expectEqual(@as(u64, 0b00111001), words[0]);
    try testing.expectEqual(@as(u2, 0b11), p.get(2));
    p.set(3, 0b11);
    try testing.expectEqual(@as(u64, 0b11111001), words[0]);
    try testing.expectEqual(@as(u2, 0b11), p.get(3));
    p.set(3, 0b01);
    try testing.expectEqual(@as(u64, 0b01111001), words[0]);
    try testing.expectEqual(@as(u2, 0b01), p.get(3));
    p.set(3, 0b00);
    try testing.expectEqual(@as(u64, 0b00111001), words[0]);
    try testing.expectEqual(@as(u2, 0b00), p.get(3));

    p.set(4, 0b11);
    try testing.expectEqual(@as(u64, 0b0000000000000000000000000000000000000000000000000000001100111001), words[0]);
    p.set(31, 0b11);
    try testing.expectEqual(@as(u64, 0b1100000000000000000000000000000000000000000000000000001100111001), words[0]);
}

test "PackedUnsignedIntegerArray: fuzz" {
    const seed = 42;

    var prng = std.rand.DefaultPrng.init(seed);
    const random = prng.random();

    inline for (.{ u1, u2, u4 }) |UInt| {
        const Context = ArrayTestContext(UInt);

        var context = try Context.init(random, 1024);
        defer context.deinit();

        try context.run();
    }
}

fn BitMaskIter(comptime MaskInt: type) type {
    return struct {
        const Self = @This();
        const BitIndex = math.Log2Int(MaskInt);

        mask: MaskInt,

        /// Iterate over the bitmask, consuming it. Returns the bit index of
        /// each set bit until there are no more set bits, then null.
        fn next(it: *Self) ?BitIndex {
            if (it.mask == 0) return null;
            // This int cast is safe since we never pass 0 to @ctz().
            const ret = @intCast(BitIndex, @ctz(MaskInt, it.mask));
            // Zero the lowest set bit
            it.mask &= it.mask - 1;
            return ret;
        }
    };
}

test "BitMaskIter" {
    const testing = @import("std").testing;

    var bit_mask = BitMaskIter(u16){ .mask = 0b1000_0000_0100_0101 };

    for ([_]u4{ 0, 2, 6, 15 }) |e| {
        try testing.expectEqual(@as(?u4, e), bit_mask.next());
    }
    try testing.expectEqual(bit_mask.next(), null);
}

test "SetAssociativeCache: matches_bitmask()" {
    const testing = std.testing;

    const log = false;
    const seed = 42;

    const Key = u64;
    const Value = u64;

    const context = struct {
        inline fn key_from_value(value: Value) Key {
            return value;
        }
        inline fn hash(key: Key) u64 {
            return key;
        }
        inline fn equal(a: Key, b: Key) bool {
            return a == b;
        }
    };

    const layout: Layout = .{};
    const SAC = SetAssociativeCache(
        Key,
        Value,
        context.key_from_value,
        context.hash,
        context.equal,
        layout,
    );
    if (log) SAC.inspect();

    const Tag = meta.Int(.unsigned, layout.tag_bits);

    const reference = struct {
        inline fn matches_bitmask(tags: *[layout.ways]Tag, tag: Tag) SAC.MatchesBitmask {
            var matches: SAC.MatchesBitmask = 0;
            for (tags) |t, i| {
                if (t == tag) {
                    matches |= @as(SAC.MatchesBitmask, 1) << @intCast(math.Log2Int(SAC.MatchesBitmask), i);
                }
            }
            return matches;
        }
    };

    var prng = std.rand.DefaultPrng.init(seed);
    const random = prng.random();

    var iterations: usize = 0;
    while (iterations < 10_000) : (iterations += 1) {
        var tags: [layout.ways]Tag = undefined;
        random.bytes(&tags);

        const tag = random.int(Tag);

        var indexes: [layout.ways]usize = undefined;
        for (indexes) |*x, i| x.* = i;
        random.shuffle(usize, &indexes);

        const matches_count_min = random.uintAtMostBiased(u32, layout.ways);
        for (indexes[0..matches_count_min]) |index| {
            tags[index] = tag;
        }

        const expected = reference.matches_bitmask(&tags, tag);
        const actual = SAC.matches_bitmask(&tags, tag);
        if (log) std.debug.print("expected: {b:0>16}, actual: {b:0>16}\n", .{ expected, actual });
        try testing.expectEqual(expected, actual);
    }
}