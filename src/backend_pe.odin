package titania

import "core:os"
import "core:bytes"

IMAGE_BASE         :: 0x400000
TEXT_BASE          :: 0x1000
FILE_ALIGN         :: 512
SECT_ALIGN         :: 0x1000
IMPORT_REGION_SIZE :: 256

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

// Build the msvcrt.dll import region and return the absolute VAs the backend
// needs (IAT slots for printf/exit, and the format strings).
pe_create_imports :: proc() -> (region: [IMPORT_REGION_SIZE]u8, iat_printf, iat_exit, fmt_int, fmt_int_nl, fmt_nl: u64) {
	put_u32 :: proc(b: []u8, v: u32) {
		b[0] = u8(v)
		b[1] = u8(v >> 8)
		b[2] = u8(v >> 16)
		b[3] = u8(v >> 24)
	}
	put_u64 :: proc(b: []u8, v: u64) {
		for i in 0..<8 {
			b[i] = u8(v >> (uint(i) * 8))
		}
	}

	b := region[:]

	// Import descriptor[0]
	put_u32(b[0:],  TEXT_BASE + 40) // OriginalFirstThunk -> INT
	put_u32(b[12:], TEXT_BASE + 88) // Name -> "msvcrt.dll"
	put_u32(b[16:], TEXT_BASE + 64) // FirstThunk -> IAT
	// descriptor[1] is a zeroed terminator

	// Import Name Table (INT) and Import Address Table (IAT): u64 thunks
	put_u64(b[40:], TEXT_BASE + 100) // printf name
	put_u64(b[48:], TEXT_BASE + 112) // exit name
	put_u64(b[64:], TEXT_BASE + 100)
	put_u64(b[72:], TEXT_BASE + 112)

	copy(b[88:],  "msvcrt.dll\x00")
	copy(b[100:], "\x00\x00printf\x00")
	copy(b[112:], "\x00\x00exit\x00")
	copy(b[120:], "%lld\x00")
	copy(b[128:], "%lld\n\x00")
	copy(b[136:], "\n\x00")

	iat_printf = IMAGE_BASE + TEXT_BASE + 64
	iat_exit   = IMAGE_BASE + TEXT_BASE + 72
	fmt_int    = IMAGE_BASE + TEXT_BASE + 120
	fmt_int_nl = IMAGE_BASE + TEXT_BASE + 128
	fmt_nl     = IMAGE_BASE + TEXT_BASE + 136
	return
}

pe_write_exe :: proc(filename: string, section: []u8, entry_rva, image_size, import_dir_va, import_dir_size, iat_va, iat_size: u32) -> os.Error {
	write_pad :: proc(b: ^bytes.Buffer, n: int) {
		for _ in 0..<n {
			bytes.buffer_write_byte(b, 0)
		}
	}
	write_ptr :: proc(b: ^bytes.Buffer, ptr: ^$T) {
		bytes.buffer_write_ptr(b, ptr, size_of(T))
	}

	calc_padding :: proc(num, align: int) -> int {
		if num % align == 0 {
			return 0
		}
		return align - num % align
	}

	b := &bytes.Buffer{}
	defer bytes.buffer_destroy(b)

	raw_size := u32(len(section) + calc_padding(len(section), FILE_ALIGN))

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

	write_pad(b, calc_padding(len(b.buf), FILE_ALIGN))
	bytes.buffer_write(b, section)
	write_pad(b, int(raw_size) - len(section))

	return os.write_entire_file(filename, bytes.buffer_to_bytes(b))
}
