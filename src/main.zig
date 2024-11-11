const std = @import("std");
const Allocator = std.mem.Allocator;
const wlb = @import("wl_bindings");
const sphwayland = @import("sphwayland");
const c = @cImport({
    @cInclude("stb_image.h");
});

const Interfaces = struct { data_control_manager: ?wlb.ZwlrDataControlManagerV1 = null, seat: ?wlb.WlSeat = null };

const Mime = union(enum) {
    // Order here determines which mimes are preferred
    image: ImageMime,
    text: TextMime,

    fn toString(self: Mime) [:0]const u8 {
        return switch (self) {
            .text => |t| @tagName(t),
            .image => |t| @tagName(t),
        };
    }
};

const TextMime = enum {
    // Order here determines which mimes are preferred
    @"text/plain;charset=utf-8",
    UTF8_STRING,
    @"text/plain",
};

const ImageMime = enum {
    // Order here determines which mimes are preferred
    @"image/png",

    fn extension(self: ImageMime) [:0]const u8 {
        return switch (self) {
            .@"image/rgba" => "raw",
            .@"image/jpeg" => "jpg",
            .@"image/png" => "png",
        };
    }
};

fn pickPasteMime(mimes: []Mime) !?Mime {
    const lessThan = struct {
        fn f(_: void, lhs: Mime, rhs: Mime) bool {
            const lhs_tag = std.meta.activeTag(lhs);
            const rhs_tag = std.meta.activeTag(rhs);
            if (lhs_tag == rhs_tag) {
                switch (lhs_tag) {
                    .image => return @intFromEnum(lhs.image) < @intFromEnum(rhs.image),
                    .text => return @intFromEnum(lhs.text) < @intFromEnum(rhs.text),
                }
            }

            return @intFromEnum(lhs_tag) < @intFromEnum(rhs_tag);
        }
    }.f;

    return std.sort.min(Mime, mimes, {}, lessThan) orelse return null;
}

const DesiredInterface = enum {
    zwlr_data_control_manager_v1,
    wl_seat,
};

fn bindInterfaces(client: *sphwayland.Client(wlb)) !Interfaces {
    var it = client.eventIt();
    try it.retrieveEvents();
    var ret = Interfaces{};

    while (try it.getAvailableEvent()) |event| {
        switch (event.event) {
            .wl_registry => |registry_event| {
                switch (registry_event) {
                    .global => |g| {
                        const interface = std.meta.stringToEnum(DesiredInterface, g.interface) orelse {
                            sphwayland.logUnusedEvent(event.event);
                            continue;
                        };

                        switch (interface) {
                            .zwlr_data_control_manager_v1 => {
                                ret.data_control_manager = try client.bind(wlb.ZwlrDataControlManagerV1, g);
                            },
                            .wl_seat => {
                                ret.seat = try client.bind(wlb.WlSeat, g);
                            },
                        }
                    },
                    else => sphwayland.logUnusedEvent(event.event),
                }
            },
            else => sphwayland.logUnusedEvent(event.event),
        }
    }

    return ret;
}

const Offer = struct {
    wl: wlb.ZwlrDataControlOfferV1,
    mimes: std.ArrayListUnmanaged(Mime) = .{},

    fn deinit(self: *Offer, alloc: Allocator) void {
        self.mimes.deinit(alloc);
    }
};

pub const Image = struct {
    // RGBA
    data: []const u8,
    width: usize,

    fn deinit(self: *Image, alloc: Allocator) void {
        alloc.free(self.data);
    }

    fn calcStride(self: Image) usize {
        return self.width * 4;
    }

    fn calcHeight(self: Image) usize {
        return self.data.len / self.calcStride();
    }
};

const ClipboardContents = union(enum) {
    text: []const u8,
    image: Image,

    fn deinit(self: *ClipboardContents, alloc: Allocator) void {
        switch (self.*) {
            .text => |s| alloc.free(s),
            .image => |*i| i.deinit(alloc),
        }
    }
};

const Clipboard = struct {
    alloc: Allocator,
    client: sphwayland.Client(wlb),
    last_offer: ?Offer = null,
    last_clipboard_offer: ?Offer = null,

    pub fn init(alloc: Allocator) !Clipboard {
        var client = try sphwayland.Client(wlb).init(alloc);
        errdefer client.deinit();

        const interfaces = try bindInterfaces(&client);

        const data_device = try client.newId(wlb.ZwlrDataControlDeviceV1);
        try interfaces.data_control_manager.?.getDataDevice(client.writer(), .{
            .id = data_device.id,
            .seat = interfaces.seat.?.id,
        });

        return .{
            .alloc = alloc,
            .client = client,
        };
    }

    pub fn deinit(self: *Clipboard) void {
        if (self.last_offer) |*o| o.deinit(self.alloc);
        if (self.last_clipboard_offer) |*o| o.deinit(self.alloc);
        self.client.deinit();
    }

    // FIXME: Either we should not expose raw data, or we should let the user
    // pick the mime type
    pub fn getClipboardContents(self: *Clipboard) !?ClipboardContents {
        const offer = self.last_clipboard_offer orelse return null;

        const paste_mime = try pickPasteMime(offer.mimes.items) orelse return null;

        var send_message = std.ArrayList(u8).init(self.alloc);
        defer send_message.deinit();

        try offer.wl.receive(send_message.writer(), .{ .mime_type = paste_mime.toString(), .fd = {} });

        const rx, const tx = try std.posix.pipe();
        try sphwayland.sendMessageWithFdAttachment(self.alloc, self.client.stream, send_message.items, tx);

        std.posix.close(tx);

        var data = std.ArrayList(u8).init(self.alloc);
        defer data.deinit();

        while (true) {
            var buf: [4096]u8 = undefined;
            const len = try std.posix.read(rx, &buf);
            if (len == 0) break;
            try data.appendSlice(buf[0..len]);
        }

        switch (paste_mime) {
            .text => return .{
                .text = try data.toOwnedSlice(),
            },
            .image => |im| return .{
                .image = try parseImage(self.alloc, im, data.items),
            },
        }
    }

    fn hasContent(self: Clipboard) bool {
        return self.last_clipboard_offer != null;
    }

    fn handleDeviceEvent(self: *Clipboard, event: wlb.ZwlrDataControlDeviceV1.Event) !void {
        switch (event) {
            .data_offer => |offer| {
                try self.client.registerId(offer.id, .zwlr_data_control_offer_v1);
                const offer_obj = wlb.ZwlrDataControlOfferV1{ .id = offer.id };

                if (self.last_offer) |*last_offer| {
                    last_offer.deinit(self.alloc);
                }

                self.last_offer = Offer{
                    .wl = offer_obj,
                };
            },
            .selection => |selection| {
                const offer: *Offer = if (self.last_offer) |*offer| offer else {
                    std.log.warn("No offer for selection message", .{});
                    return;
                };

                if (offer.wl.id != selection.id) {
                    std.log.warn("Clipboard message for different offer id", .{});
                    return;
                }

                self.last_clipboard_offer = self.last_offer;
                self.last_offer = null;
            },
            else => {
                std.log.debug("Unused event: {any}", .{event});
            },
        }
    }

    fn handleOfferEvent(self: *Clipboard, id: u32, event: wlb.ZwlrDataControlOfferV1.Event) !void {
        comptime {
            std.debug.assert(std.meta.fields(@TypeOf(event)).len == 1);
        }

        const offer = if (self.last_offer) |*offer| offer else {
            std.log.warn("No offer for offer event", .{});
            return;
        };

        if (offer.wl.id != id) {
            std.log.warn("Offer event for invalid offer", .{});
            return;
        }

        if (std.meta.stringToEnum(ImageMime, event.offer.mime_type)) |im| {
            try offer.mimes.append(self.alloc, .{ .image = im });
        } else if (std.meta.stringToEnum(TextMime, event.offer.mime_type)) |tm| {
            try offer.mimes.append(self.alloc, .{ .text = tm });
        }
    }

    fn handleEvent(self: *Clipboard, event: sphwayland.EventIt(wlb).Event) !void {
        switch (event.event) {
            .zwlr_data_control_device_v1 => |device_event| try self.handleDeviceEvent(device_event),
            .zwlr_data_control_offer_v1 => |offer_event| try self.handleOfferEvent(event.object_id, offer_event),
            else => sphwayland.logUnusedEvent(event.event),
        }
    }

    // Clipboard needs to be serviced every once in a while to consume messages
    // from the compositor etc.
    fn service(self: *Clipboard) !void {
        var it = self.client.eventIt();
        while (try it.getAvailableEvent()) |event| try self.handleEvent(event);
    }

    fn serviceBlocking(self: *Clipboard) !void {
        var it = self.client.eventIt();

        const event = try it.getEventBlocking();
        try self.handleEvent(event);
    }
};

fn parseImage(alloc: Allocator, mime: ImageMime, data: []const u8) !Image {
    std.debug.assert(mime == .@"image/png");

    var width: c_int = 0;
    var height: c_int = 0;

    const parsed_image = c.stbi_load_from_memory(data.ptr, @intCast(data.len), &width, &height, null, 4);
    if (parsed_image == null) {
        return error.LoadImage;
    }
    defer c.stbi_image_free(parsed_image);

    if (width < 0 or height < 0) {
        return error.InvalidImageDims;
    }

    const len: usize = @intCast(width * height * 4);
    const output = try alloc.alloc(u8, len);
    @memcpy(output, parsed_image[0..len]);

    return .{
        .data = output,
        .width = @intCast(width),
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var clipboard = try Clipboard.init(alloc);
    defer clipboard.deinit();

    while (true) {
        try clipboard.serviceBlocking();
        if (clipboard.hasContent()) {
            var content = (try clipboard.getClipboardContents()) orelse continue;
            defer content.deinit(alloc);

            switch (content) {
                .text => |s| std.debug.print("Content: {s}\n", .{s}),
                .image => |i| {
                    std.debug.print("Image: {d}x{d}\n", .{ i.width, i.calcHeight() });
                },
            }
            break;
        }
    }
}
