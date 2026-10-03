"""Read-only x64 Windows process probe; reports proxy names, never values."""
import argparse
import ctypes as c
from ctypes import wintypes as w
import json
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--pid', type=int, action='append', required=True)
args = parser.parse_args()
if sys.platform != 'win32' or c.sizeof(c.c_void_p) != 8:
    parser.error('Run with 64-bit Python on Windows; no process was modified.')

kernel = c.WinDLL('kernel32', use_last_error=True)
nt = c.WinDLL('ntdll')
kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
kernel.OpenProcess.restype = w.HANDLE
kernel.ReadProcessMemory.argtypes = [w.HANDLE, c.c_void_p, c.c_void_p, c.c_size_t, c.POINTER(c.c_size_t)]
kernel.ReadProcessMemory.restype = w.BOOL
kernel.IsWow64Process.argtypes = [w.HANDLE, c.POINTER(w.BOOL)]
kernel.IsWow64Process.restype = w.BOOL
kernel.CloseHandle.argtypes = [w.HANDLE]
class MemoryRegion(c.Structure):
    _fields_ = [('BaseAddress',c.c_void_p),('AllocationBase',c.c_void_p),('AllocationProtect',w.DWORD),
                ('PartitionId',w.WORD),('RegionSize',c.c_size_t),('State',w.DWORD),('Protect',w.DWORD),('Type',w.DWORD)]
kernel.VirtualQueryEx.argtypes = [w.HANDLE,c.c_void_p,c.POINTER(MemoryRegion),c.c_size_t]
kernel.VirtualQueryEx.restype = c.c_size_t
nt.NtQueryInformationProcess.argtypes = [w.HANDLE, w.ULONG, c.c_void_p, w.ULONG, c.POINTER(w.ULONG)]
failed = False
for pid in args.pid:
    handle = kernel.OpenProcess(0x410, False, pid)
    if not handle:
        print(json.dumps({'pid': pid, 'error': f'OpenProcess {c.get_last_error()}'}))
        failed = True
        continue
    try:
        wow64 = w.BOOL()
        if not kernel.IsWow64Process(handle, c.byref(wow64)) or wow64.value:
            raise RuntimeError('Target must be a readable 64-bit Windows process.')
        basic = (c.c_ulonglong * 6)()
        length = w.ULONG()
        status = nt.NtQueryInformationProcess(handle, 0, c.byref(basic), c.sizeof(basic), c.byref(length))
        if status:
            raise RuntimeError(f'NtQueryInformationProcess {status}')
        def read(address, size):
            region = MemoryRegion()
            if not kernel.VirtualQueryEx(handle,address,c.byref(region),c.sizeof(region)):
                raise RuntimeError(f'VirtualQueryEx {c.get_last_error()}')
            size = min(size, int(region.BaseAddress) + region.RegionSize - address)
            if size <= 0:
                raise RuntimeError('No readable bytes in process memory region.')
            buffer = c.create_string_buffer(size)
            got = c.c_size_t()
            kernel.ReadProcessMemory(handle, address, buffer, size, c.byref(got))
            if not got.value:
                raise RuntimeError(f'ReadProcessMemory {c.get_last_error()}')
            return buffer.raw[:got.value]
        parameters = int.from_bytes(read(basic[1] + 0x20, 8), 'little')
        environment = int.from_bytes(read(parameters + 0x80, 8), 'little')
        raw = read(environment, 32768).decode('utf-16-le', errors='replace').split('\0\0', 1)[0]
        names = {entry.split('=', 1)[0].upper() for entry in raw.split('\0') if '=' in entry and not entry.startswith('=')}
        expected = ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')
        print(json.dumps({'pid': pid, 'proxyKeysPresent': [name for name in expected if name in names]}))
    except Exception as error:
        print(json.dumps({'pid': pid, 'error': str(error)}))
        failed = True
    finally:
        kernel.CloseHandle(handle)
sys.exit(1 if failed else 0)
