// ref https://github.com/floscodes/zerve/blob/main/src/types.zig
const std = @import("std");
const eql = std.mem.eql;

pub const Method = enum {
    POST,
    GET,
    PATCH,
    DELETE,
    PUT,
    OPTIONS,
    HEAD,
    TRACE,
    CONNECT,
    UNKNOWN,
    pub fn stringify(self: Method) []const u8 {
        switch (self) {
            Method.GET => return "GET",
            Method.POST => return "POST",
            Method.PUT => return "PUT",
            Method.PATCH => return "PATCH",
            Method.DELETE => return "DELETE",
            Method.HEAD => return "HEAD",
            Method.CONNECT => return "CONNECT",
            Method.OPTIONS => return "OPTIONS",
            Method.TRACE => return "TRACE",
            Method.UNKNOWN => return "UNKNOWN",
        }
    }

    /// Parses the Method from a string
    pub fn parse(value: []const u8) Method {
        if (eql(u8, value, "GET") or eql(u8, value, "get")) return Method.GET;
        if (eql(u8, value, "POST") or eql(u8, value, "post")) return Method.POST;
        if (eql(u8, value, "PUT") or eql(u8, value, "put")) return Method.PUT;
        if (eql(u8, value, "HEAD") or eql(u8, value, "head")) return Method.HEAD;
        if (eql(u8, value, "DELETE") or eql(u8, value, "delete")) return Method.DELETE;
        if (eql(u8, value, "CONNECT") or eql(u8, value, "connect")) return Method.CONNECT;
        if (eql(u8, value, "OPTIONS") or eql(u8, value, "options")) return Method.OPTIONS;
        if (eql(u8, value, "TRACE") or eql(u8, value, "trace")) return Method.TRACE;
        if (eql(u8, value, "PATCH") or eql(u8, value, "patch")) return Method.PATCH;
        return Method.UNKNOWN;
    }
};

/// The HTTP Version.
pub const HTTP_Version = enum {
    HTTP1_1,
    HTTP2,

    /// Parses from `[]u8`
    pub fn parse(s: []const u8) HTTP_Version {
        if (std.mem.containsAtLeast(u8, s, 1, "2")) return HTTP_Version.HTTP2 else return HTTP_Version.HTTP1_1;
    }
    /// Stringifies `HTTP_Version`
    pub fn stringify(version: HTTP_Version) []const u8 {
        switch (version) {
            HTTP_Version.HTTP1_1 => return "HTTP/1.1",
            HTTP_Version.HTTP2 => return "HTTP/2.0",
        }
    }
};
