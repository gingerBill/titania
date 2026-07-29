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


	info: Checker_Info
	checker_info_init(&info)

	for &p in parsers {
		module := new(Module)
		parse(&p, module)
		module.id = len(info.modules)+1

		if p.tok.error_count != 0 {
			free(module)
			return
		}

		check_module(&info, module)
		if module.error_count != 0 {
			return
		}

		info.modules[module.name.text] = module
		append(&info.modules_in_order, module)
	}

	last_module := info.modules_in_order[len(info.modules_in_order)-1]

	out_exe_path := fmt.aprintf("%s.exe", last_module.name.text)
	defer delete(out_exe_path)
	if generate(&info, out_exe_path) {
		fmt.println("wrote", out_exe_path)
	}
}