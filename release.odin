package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:time"
import win32 "core:sys/windows"

// Release builds (package.bat): -define:RELEASE=true makes a windowed exe
// with no console, sent to testers as a folder. It runs from its own folder
// whatever started it (resources/ and saves/ are found beside it), and what
// it would print, any assert or panic (on every thread: the runtime writes
// those to the process's stderr handle), and a crash's exception go to
// log.txt there, for them to send back with a bug report.
RELEASE      :: #config(RELEASE, false)
GAME_VERSION :: #config(VERSION, "dev") // package.bat: the date and commit

LOG_FILE :: "log.txt"
LOG_MAX  :: 4 << 20 // bigger than this, it starts over

foreign import kernel32 "system:Kernel32.lib"

@(private="file")
@(default_calling_convention="system")
foreign kernel32 {
    SetStdHandle :: proc(nStdHandle: win32.DWORD, hHandle: win32.HANDLE) -> win32.BOOL ---
}

// First thing in main.
release_init :: proc() {
    when RELEASE {
        if dir, err := os.get_executable_directory(context.allocator); err == nil {
            _ = os.set_working_directory(dir)
            delete(dir)
        }
        flags := os.File_Flags{.Write, .Create, .Append}
        if fi, err := os.stat(LOG_FILE, context.temp_allocator); err == nil && fi.size > LOG_MAX {
            flags = {.Write, .Create, .Trunc}
        }
        f, err := os.open(LOG_FILE, flags)
        if err != nil { return }
        os.stdout, os.stderr = f, f
        h := win32.HANDLE(os.fd(f))
        SetStdHandle(win32.STD_OUTPUT_HANDLE, h)
        SetStdHandle(win32.STD_ERROR_HANDLE, h)
        win32.SetUnhandledExceptionFilter(release_crashed)
        fmt.printfln("\n=== %s %s, started %v ===", GAME_NAME, GAME_VERSION, time.now())
    }
}

// A crash (access violation and the like): what and where, into the log;
// then Windows deals with it as it would have.
@(private="file")
release_crashed :: proc "system" (info: ^win32.EXCEPTION_POINTERS) -> win32.LONG {
    context = runtime.default_context()
    rec := info.ExceptionRecord
    exe_base := uintptr(win32.GetModuleHandleW(nil))
    fmt.eprintfln("CRASH: exception 0x%08X at %p (exe + 0x%X), %v", rec.ExceptionCode, rec.ExceptionAddress,
        uintptr(rec.ExceptionAddress) - exe_base, time.now())
    return 0 // EXCEPTION_CONTINUE_SEARCH
}
