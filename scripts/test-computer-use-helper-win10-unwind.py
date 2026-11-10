"""Validate the mapped x64 wrapper with Windows lookup/unwind and real call frames.

The EXE is mapped without resolving imports or running its entry point. API/COM
calls are stubbed only in this private mapping; the input file is never changed.
"""

import argparse
import ctypes as c
import hashlib
import json
import os
import struct


def require(condition, message):
    if not condition:
        raise AssertionError(message)


PROFILES = {
    'a7ef05e4dabad5e9ed22709c3a7928a21d40689db274276206ef25e87456670c': (0x17e000, 0x84f0, 0x42489),
    '5bae07883ba804d9eb23bfbffbc99fd83247896f6cfe66109a8f6c4c5ee13b94': (0x17e000, 0x84f0, 0x42489),
    '36a28644deaf935ceffad9c8ccffb04317cde7466a860304b703acbf50086201': (0x17c000, 0x849c, 0x4247a),
    '225abfb088eefbbc3d8002cb85a60447479e4e40396250afe10e648d9f4ec41a': (0x17c000, 0x849c, 0x4247a),
    '02469cd31abf82544a9ef21139c8302266ca4caef13d864d49c81c637d0ae326': (0x17e000, 0x84f0, 0x42489),
    '40b6ed3f0534ef1bf9d9f79adf13365ecd75df5dde387d8a1f0287ed72338fe8': (0x17e000, 0x84f0, 0x42489),
    '7c4dc7060a6081506c1614ea0831523ef1d68201cf34e6bd7de7fb787d63dfa2': (0x17e000, 0x84f0, 0x42489),
    '8dcc49cb8ce2d341112681f7b96d09bf129f711a74c3c7aad747d3403032ced0': (0x17e000, 0x84f0, 0x42489),
    'c1b08268538e704acfb4afe6a8fe91d26b8d7dc9e0fd8d30e92a792964f6a151': (0x17c000, 0x849c, 0x4247a),
    '7ea9a40431c84e40a4af51230c1c50588d9ce90019eb651d5a61563e7a10b59a': (0x17c000, 0x849c, 0x4247a),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("helper")
    args = parser.parse_args()
    require(os.name == "nt" and c.sizeof(c.c_void_p) == 8, "Windows x64 is required")
    with open(args.helper, 'rb') as stream:
        helper_hash = hashlib.file_digest(stream, 'sha256').hexdigest()
    require(helper_hash in PROFILES, 'Unsupported complete patched helper hash')
    wrapper, expected_exception_size, original_callback = PROFILES[helper_hash]
    kernel = c.WinDLL("kernel32", use_last_error=True)
    ntdll = c.WinDLL("ntdll")
    kernel.LoadLibraryExW.argtypes = [c.c_wchar_p, c.c_void_p, c.c_uint]
    kernel.LoadLibraryExW.restype = c.c_void_p
    kernel.FreeLibrary.argtypes = [c.c_void_p]
    kernel.VirtualAlloc.argtypes = [c.c_void_p, c.c_size_t, c.c_uint, c.c_uint]
    kernel.VirtualAlloc.restype = c.c_void_p
    kernel.VirtualFree.argtypes = [c.c_void_p, c.c_size_t, c.c_uint]
    kernel.VirtualProtect.argtypes = [c.c_void_p, c.c_size_t, c.c_uint, c.POINTER(c.c_uint)]
    kernel.FlushInstructionCache.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t]
    ntdll.RtlLookupFunctionEntry.argtypes = [c.c_uint64, c.POINTER(c.c_uint64), c.c_void_p]
    ntdll.RtlLookupFunctionEntry.restype = c.c_void_p
    ntdll.RtlVirtualUnwind.argtypes = [c.c_uint, c.c_uint64, c.c_uint64, c.c_void_p,
                                      c.c_void_p, c.POINTER(c.c_void_p),
                                      c.POINTER(c.c_uint64), c.c_void_p]
    ntdll.RtlVirtualUnwind.restype = c.c_void_p
    image = kernel.LoadLibraryExW(os.path.abspath(args.helper), None, 1)
    if not image:
        raise c.WinError(c.get_last_error())
    executable_buffers = []
    keep_alive = []

    def read64(address):
        return c.c_uint64.from_address(address).value

    def lookup(rva):
        base = c.c_uint64()
        entry = ntdll.RtlLookupFunctionEntry(image + rva, c.byref(base), None)
        require(entry and base.value == image, f"missing native function entry at {rva:#x}")
        return entry

    def unwind(rva, stack, rbx):
        buffer = c.create_string_buffer(1250)
        context = (c.addressof(buffer) + 15) & ~15
        c.c_uint32.from_address(context + 48).value = 0x100003
        c.c_uint64.from_address(context + 144).value = rbx
        c.c_uint64.from_address(context + 152).value = stack
        c.c_uint64.from_address(context + 248).value = image + rva
        handler_data = c.c_void_p()
        frame = c.c_uint64()
        handler = ntdll.RtlVirtualUnwind(0, image, image + rva, lookup(rva), context,
                                        c.byref(handler_data), c.byref(frame), None)
        require(not handler, "wrapper unexpectedly has a language handler")
        return read64(context + 248), read64(context + 152), read64(context + 144)

    def write_mapping(rva, data):
        old = c.c_uint()
        if not kernel.VirtualProtect(image + rva, len(data), 0x40, c.byref(old)):
            raise c.WinError(c.get_last_error())
        c.memmove(image + rva, data, len(data))
        previous = c.c_uint()
        require(kernel.VirtualProtect(image + rva, len(data), old.value, c.byref(previous)),
                "could not restore mapped-page protection")
        require(kernel.FlushInstructionCache(c.c_void_p(-1), image + rva, len(data)),
                "could not flush instruction cache")

    def capture_stub(result):
        # Copy the live caller's RIP/RBX and stack before returning. No nonvolatile
        # register or RSP is changed, so this test stub itself remains a leaf.
        snapshot = c.create_string_buffer(128)
        keep_alive.append(snapshot)
        address = c.addressof(snapshot)
        code = bytearray(b"\x49\xba" + struct.pack("<Q", address))  # mov r10, snapshot
        code += bytes.fromhex("49ff4278488b042449890249895a08488d44240849894250")
        # Header: return RIP at 0, live RBX at 8, copied stack at 16..79.
        # The live caller's RSP is recorded separately at offset 80.
        for offset in range(0, 64, 8):
            code += b"\x4c\x8b\x5c\x24" + bytes([8 + offset])
            code += b"\x4d\x89\x5a" + bytes([16 + offset])
        code += b"\xb8" + struct.pack("<I", result) + b"\xc3"
        ptr = kernel.VirtualAlloc(None, len(code), 0x3000, 0x04)
        require(ptr, "VirtualAlloc failed")
        executable_buffers.append(ptr)
        c.memmove(ptr, bytes(code), len(code))
        old = c.c_uint()
        require(kernel.VirtualProtect(ptr, len(code), 0x20, c.byref(old)), "RX protection failed")
        require(kernel.FlushInstructionCache(c.c_void_p(-1), ptr, len(code)), "cache flush failed")
        return ptr, snapshot

    try:
        pe = c.c_uint32.from_address(image + 0x3c).value
        exception_rva, exception_size = struct.unpack("<II", c.string_at(image + pe + 24 + 112 + 24, 8))
        require(exception_size == expected_exception_size, "unexpected exception directory size")
        table = c.string_at(image + exception_rva, exception_size)
        entries = list(struct.iter_unpack("<III", table))
        require(all(a[1] <= b[0] for a, b in zip(entries, entries[1:])), "unsorted/overlapping functions")
        require(entries[-2:] == [(wrapper, wrapper + 0x72, wrapper + 0xc0),
                                (wrapper + 0x80, wrapper + 0xb2, wrapper + 0xc8)], "wrong wrapper ranges")
        lookup(original_callback)
        boundaries = [
            (wrapper, 0x30, [0, 1, 5, 8, 12, 18, 20, 23, 26, 28, 30, 37, 40,
                              49, 58, 64, 67, 69, 72, 78, 80, 84, 85, 86, 90, 94,
                              97, 100, 103, 108, 112, 113], [80, 108]),
            (wrapper + 0x80, 0x20, [0, 1, 5, 8, 13, 19, 22, 27, 33, 36, 39, 42, 44, 48, 49], [44]),
        ]
        saved_rbx = 0x1122334455667788
        caller_rip = 0x1234567812345678
        synthetic_count = 0
        for entry, allocation, offsets, epilogs in boundaries:
            require(c.string_at(image + entry, 5) == b"\x53\x48\x83\xec" + bytes([allocation]),
                    "unrecognized wrapper prolog")
            for offset in offsets:
                stack_buffer = c.create_string_buffer(256)
                top = ((c.addressof(stack_buffer) + 128 + 15) & ~15) + 8
                c.c_uint64.from_address(top).value = caller_rip
                c.c_uint64.from_address(top - 8).value = saved_rbx
                stack = top if offset == 0 else top - 8 if offset == 1 else top - 8 - allocation
                rbx = saved_rbx if offset <= 5 else 0x9988776655443322
                for epilog in epilogs:
                    if offset == epilog + 4:
                        stack = top - 8
                    if offset == epilog + 5:
                        stack, rbx = top, saved_rbx
                actual = unwind(entry + offset, stack, rbx)
                require(actual == (caller_rip, top + 8, saved_rbx),
                        f"native unwind failed at {entry+offset:#x}: {actual}")
                synthetic_count += 1

        vtable = (c.c_uint64 * 3)()
        state = c.create_string_buffer(64)
        instance = (c.c_uint64 * 2)(c.addressof(vtable), c.addressof(state))
        snapshots = {}

        def stub(name, result):
            address, snapshot = capture_stub(result)
            snapshots[name] = snapshot
            return address

        vtable[1] = stub("addref", 1)
        vtable[2] = stub("release", 1)
        callback_code = c.string_at(image + wrapper, 0x72)
        worker_code = c.string_at(image + wrapper + 0x80, 0x32)

        def import_slots(code, start):
            offsets = [i for i in range(len(code) - 5) if code[i:i + 2] == b'\xff\x15']
            require(len(offsets) == 2, 'Unexpected pinned wrapper import calls')
            return [start + i + 6 + struct.unpack_from('<i', code, i + 2)[0] for i in offsets]

        create_slot, close_slot = import_slots(callback_code, wrapper)
        initialize_slot, uninitialize_slot = import_slots(worker_code, wrapper + 0x80)
        write_mapping(close_slot, struct.pack("<Q", stub("close", 1)))
        write_mapping(initialize_slot, struct.pack("<Q", stub("initialize", 0)))
        write_mapping(uninitialize_slot, struct.pack("<Q", stub("uninitialize", 0)))
        original = stub("original", 0)
        write_mapping(original_callback, b"\x48\xb8" + struct.pack("<Q", original) + b"\xff\xe0")
        callback = c.WINFUNCTYPE(c.c_uint32, c.c_void_p)(image + wrapper)
        worker = c.WINFUNCTYPE(c.c_uint32, c.c_void_p)(image + wrapper + 0x80)
        call_cases = []
        for name, target, create_result, expected_result, expected_calls in [
            ("success", callback, 1, 0, {"addref", "create", "close"}),
            ("create-failure", callback, 0, 0x80004005, {"addref", "create", "release"}),
            ("busy", callback, 1, 0, set()),
            ("worker", worker, 1, 0, {"initialize", "original", "uninitialize", "release"}),
        ]:
            write_mapping(create_slot, struct.pack("<Q", stub("create", create_result)))
            for snapshot in snapshots.values():
                c.memset(c.addressof(snapshot), 0, len(snapshot))
            c.memset(c.addressof(state), 0, len(state))
            if name == "busy":
                c.c_ubyte.from_address(c.addressof(state) + 17).value = 1
            require(target(c.addressof(instance)) == expected_result, f"wrong {name} return")
            called = {key for key, value in snapshots.items() if read64(c.addressof(value) + 120)}
            require(called == expected_calls, f"wrong {name} calls: {called}")
            if name == "create-failure":
                require(c.c_ubyte.from_address(c.addressof(state) + 17).value == 0, "busy flag not cleared")
            for key in called:
                snapshot = c.addressof(snapshots[key])
                rip = read64(snapshot)
                live_rbx = read64(snapshot + 8)
                stack = snapshot + 16
                allocation = 0x20 if name == "worker" else 0x30
                require(read64(snapshot + 80) % 16 == 0, "misaligned live call stack")
                caller = read64(stack + allocation + 8)
                original_rbx = read64(stack + allocation)
                require(live_rbx == c.addressof(instance), "live RBX was not the callback object")
                require(caller != 0 and original_rbx != live_rbx, "invalid live caller frame")
                require(unwind(rip - image, stack, live_rbx) ==
                        (caller, stack + allocation + 16, original_rbx), f"live unwind failed: {name}/{key}")
                if key == "create":
                    require(read64(stack + 32) == 0 and read64(stack + 40) == 0,
                            "CreateThread stack arguments are not zero")
            call_cases.append({"case": name, "liveFramesUnwound": len(called)})
        print(json.dumps({"result": "PASS", "helperSha256": helper_hash, "functionEntries": len(entries),
                          "instructionBoundaries": synthetic_count, "callCases": call_cases}))
    finally:
        kernel.FreeLibrary(image)
        for pointer in executable_buffers:
            kernel.VirtualFree(pointer, 0, 0x8000)


if __name__ == "__main__":
    main()
