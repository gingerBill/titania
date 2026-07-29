package titania

import "core:path/filepath"
import "core:mem/virtual"
import "core:os"
import "core:fmt"

main :: proc() {
	parsers := make([dynamic]Parser, 0, len(os.args))
	defer delete(parsers)
	defer for &p in parsers {
		parser_fini(&p)
	}

	for arg in os.args[1:] {
		filename, _ := filepath.abs(arg)

		p: Parser
		if !parser_init(&p, filename) {
			return
		}
		append(&parsers, p)
	}

	for &p in parsers {
		module: Module
		parse(&p, &module)

		if p.tok.error_count != 0 {
			return
		}

		info: Checker_Info
		checker_info_init(&info)

		check_module(&info, &module)

		if module.error_count != 0 {
			return
		}

		out_exe_path := fmt.aprintf("%s.exe", module.name.text)
		defer delete(out_exe_path)
		if generate(&module, out_exe_path) {
			fmt.println("wrote", out_exe_path)
		}
	}
}