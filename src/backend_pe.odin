package titania

import "core:os"
import "core:bytes"

IMAGE_BASE         :: 0x400000
TEXT_BASE          :: 0x1000
FILE_ALIGN         :: 512
SECT_ALIGN         :: 0x1000
IMPORT_REGION_SIZE :: 512

PEFileHeader :: struct #packed {
	Magic:                [4]u8,
	Machine:              u16,
	NumberOfSections:     u16,
	TimeDateStamp:        u32,
	PointerToSymbolTable: u32,
	NumberOfSymbols:      u32,
	SizeOfOptionalHeader: u16,
	Characteristics:      IMAGE_FILE_SET,
}

DataDirectory :: struct #packed {
	VirtualAddress: u32,
	Size:           u32,
}

OptionalHeader64 :: struct #packed {
	Magic:                       u16,
	MajorLinkerVersion:          u8,
	MinorLinkerVersion:          u8,
	SizeOfCode:                  u32,
	SizeOfInitializedData:       u32,
	SizeOfUninitializedData:     u32,
	AddressOfEntryPoint:         u32,
	BaseOfCode:                  u32,
	ImageBase:                   u64,
	SectionAlignment:            u32,
	FileAlignment:               u32,
	MajorOperatingSystemVersion: u16,
	MinorOperatingSystemVersion: u16,
	MajorImageVersion:           u16,
	MinorImageVersion:           u16,
	MajorSubsystemVersion:       u16,
	MinorSubsystemVersion:       u16,
	Win32VersionValue:           u32,
	SizeOfImage:                 u32,
	SizeOfHeaders:               u32,
	CheckSum:                    u32,
	Subsystem:                   IMAGE_SUBSYSTEM,
	DllCharacteristics:          IMAGE_DLLCHARACTERISTICS,
	SizeOfStackReserve:          u64,
	SizeOfStackCommit:           u64,
	SizeOfHeapReserve:           u64,
	SizeOfHeapCommit:            u64,
	LoaderFlags:                 u32,
	NumberOfRvaAndSizes:         u32,
	DataDirectory:               [16]DataDirectory,
}

SectionHeader :: struct #packed {
	Name:                 [8]u8,
	VirtualSize:          u32,
	VirtualAddress:       u32,
	SizeOfRawData:        u32,
	PointerToRawData:     u32,
	PointerToRelocations: u32,
	PointerToLineNumbers: u32,
	NumberOfRelocations:  u16,
	NumberOfLineNumbers:  u16,
	Characteristics:      u32,
}

IMAGE_FILE_MACHINE_AMD64 :: 0x8664

IMAGE_FILE_SET :: distinct bit_set[IMAGE_FILE; u16]
IMAGE_FILE :: enum u16 {
	RELOCS_STRIPPED     = 0,
	EXECUTABLE_IMAGE    = 1,
	LINE_NUMS_STRIPPED  = 2,
	LOCAL_SYMS_STRIPPED = 3,
	LARGE_ADDRESS_AWARE = 5,
	DEBUG_STRIPPED      = 8,
}

IMAGE_SUBSYSTEM :: enum u16 {
	WINDOWS_GUI = 2,
	WINDOWS_CUI = 3,
}

IMAGE_DLLCHARACTERISTICS :: distinct bit_set[IMAGE_DLLCHARACTERISTIC; u16]
IMAGE_DLLCHARACTERISTIC :: enum u16 {
	DYNAMIC_BASE = 6,
	NX_COMPAT    = 8,
}

OPTIONAL_HEADER_MAGIC_PE32_PLUS :: 0x020b

IMAGE_SCN_CNT_CODE    :: 0x00000020
IMAGE_SCN_MEM_EXECUTE :: 0x20000000
IMAGE_SCN_MEM_READ    :: 0x40000000
IMAGE_SCN_MEM_WRITE   :: 0x80000000

IAT_Func :: enum {
	printf,
	exit,
	floor,
	ceil,
	calloc,
	free,
	memmove,
	ldexp,
	frexp,
}
@(rodata)
iat_func_strings := [IAT_Func]string{
	.printf  = "printf",
	.exit    = "exit",
	.floor   = "floor",
	.ceil    = "ceil",
	.calloc  = "calloc",
	.free    = "free",
	.memmove = "memmove",
	.ldexp   = "ldexp",
	.frexp   = "frexp",
}

Fmt_Kind :: enum {
	int,
	int_nl,
	nl,
	real,
	real_nl,
	str,
	str_nl,
	ptr,
	ptr_nl,

	assert,

	set_open,
	set_close,
	set_close_nl,
	set_sep,
}
@(rodata)
fmt_kind_formats := [Fmt_Kind]string{
	.int     = "%lld",
	.int_nl  = "%lld\n",
	.nl      = "\n",
	.real    = "%g",
	.real_nl = "%g\n",
	.str     = "%s",
	.str_nl  = "%s\n",
	.ptr     = "0x%016llx",
	.ptr_nl  = "0x%016llx\n",

	.assert  = "assertion failed\n",

	.set_open     = "{",
	.set_close    = "}",
	.set_close_nl = "}\n",
	.set_sep      = ", %lld",
}


// Absolute virtual addresses that the backend needs from the import region.
Imports :: struct {
	funcs: [IAT_Func]u64,
	fmts:  [Fmt_Kind]u64,

	iat_rva:  u32,
	iat_size: u32,
}

pe_put_u32 :: proc(b: []u8, v: u32) {
	b[0] = u8(v)
	b[1] = u8(v >> 8)
	b[2] = u8(v >> 16)
	b[3] = u8(v >> 24)
}
pe_put_u64 :: proc(b: []u8, v: u64) {
	for i in 0..<8 {
		b[i] = u8(v >> (uint(i) * 8))
	}
}

// Build the msvcrt.dll import region for a fixed set of C functions and return
// the absolute VAs the backend needs (IAT slots and format strings).
pe_create_imports :: proc() -> (region: [IMPORT_REGION_SIZE]u8, imp: Imports) {
	b := region[:]

	put_cstr :: proc(b: []u8, cur: ^int, s: string) -> u64 {
		off := cur^
		copy(b[off:], s)
		b[off + len(s)] = 0
		cur^ = off + len(s) + 1
		if cur^ % 2 != 0 { cur^ += 1 }
		return IMAGE_BASE + TEXT_BASE + u64(off)
	}

	nf := len(iat_func_strings)

	int_off   := 40
	iat_off   := int_off + (nf + 1) * 8
	names_off := iat_off + (nf + 1) * 8

	// Import descriptor[0] (descriptor[1] is a zeroed terminator).
	pe_put_u32(b[0:],  u32(TEXT_BASE + int_off)) // OriginalFirstThunk -> INT
	pe_put_u32(b[16:], u32(TEXT_BASE + iat_off)) // FirstThunk        -> IAT

	cur := names_off
	dll_off := cur
	copy(b[cur:], "msvcrt.dll\x00"); cur += 11
	if cur % 2 != 0 { cur += 1 }
	pe_put_u32(b[12:], u32(TEXT_BASE + dll_off)) // Name -> "msvcrt.dll"

	for fn, func_enum in iat_func_strings {
		i := int(func_enum)
		byname := cur
		copy(b[byname + 2:], fn) // 2-byte hint (0) precedes the name
		b[byname + 2 + len(fn)] = 0
		cur = byname + 2 + len(fn) + 1
		if cur % 2 != 0 { cur += 1 }
		pe_put_u64(b[int_off + i * 8:], u64(TEXT_BASE + byname))
		pe_put_u64(b[iat_off + i * 8:], u64(TEXT_BASE + byname))
		imp.funcs[func_enum] = IMAGE_BASE + TEXT_BASE + u64(iat_off + i * 8)	}

	imp.iat_rva     = u32(TEXT_BASE + iat_off)
	imp.iat_size    = u32(nf * 8)

	for str, kind in fmt_kind_formats {
		imp.fmts[kind] = put_cstr(b, &cur, str)
	}
	return
}

pe_write_exe :: proc(filename: string, section: []u8, entry_rva, image_size, import_dir_va, import_dir_size, iat_va, iat_size: u32) {
	write_pad :: proc(b: ^bytes.Buffer, n: int) {
		for _ in 0..<n {
			bytes.buffer_write_byte(b, 0)
		}
	}
	write_ptr :: proc(b: ^bytes.Buffer, ptr: ^$T) {
		bytes.buffer_write_ptr(b, ptr, size_of(T))
	}
	pe_padding :: proc(num, align: int) -> int {
		if num % align == 0 {
			return 0
		}
		return align - num % align
	}

	b := &bytes.Buffer{}
	defer bytes.buffer_destroy(b)

	raw_size := u32(len(section) + pe_padding(len(section), FILE_ALIGN))

	bytes.buffer_write_string(b, "MZ")
	write_pad(b, 58)
	bytes.buffer_write_string(b, "\x40\x00\x00\x00") // e_lfanew = 0x40

	write_ptr(b, &PEFileHeader{
		Magic                = "PE\x00\x00",
		Machine              = IMAGE_FILE_MACHINE_AMD64,
		NumberOfSections     = 1,
		SizeOfOptionalHeader = size_of(OptionalHeader64),
		Characteristics      = {.EXECUTABLE_IMAGE, .LARGE_ADDRESS_AWARE, .RELOCS_STRIPPED,
		                        .DEBUG_STRIPPED, .LINE_NUMS_STRIPPED, .LOCAL_SYMS_STRIPPED},
	})

	write_ptr(b, &OptionalHeader64{
		Magic                 = OPTIONAL_HEADER_MAGIC_PE32_PLUS,
		SizeOfCode            = raw_size,
		SizeOfInitializedData = raw_size,
		AddressOfEntryPoint   = entry_rva,
		BaseOfCode            = TEXT_BASE,
		ImageBase             = IMAGE_BASE,
		SectionAlignment      = SECT_ALIGN,
		FileAlignment         = FILE_ALIGN,
		MajorSubsystemVersion = 6,
		SizeOfImage           = image_size,
		SizeOfHeaders         = FILE_ALIGN,
		Subsystem             = .WINDOWS_CUI,
		DllCharacteristics    = {.NX_COMPAT},
		SizeOfStackReserve    = 0x100000,
		SizeOfStackCommit     = 0x001000,
		SizeOfHeapReserve     = 0x100000,
		SizeOfHeapCommit      = 0x001000,
		NumberOfRvaAndSizes   = 16,
		DataDirectory = {
			1  = {VirtualAddress = import_dir_va, Size = import_dir_size},
			12 = {VirtualAddress = iat_va,        Size = iat_size},
		},
	})

	write_ptr(b, &SectionHeader{
		Name             = ".text\x00\x00\x00",
		VirtualSize      = u32(len(section)),
		VirtualAddress   = TEXT_BASE,
		SizeOfRawData    = raw_size,
		PointerToRawData = FILE_ALIGN,
		Characteristics  = IMAGE_SCN_CNT_CODE | IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE,
	})

	write_pad(b, pe_padding(len(b.buf), FILE_ALIGN))
	bytes.buffer_write(b, section)
	write_pad(b, int(raw_size) - len(section))

	_ = os.write_entire_file(filename, bytes.buffer_to_bytes(b))
}
