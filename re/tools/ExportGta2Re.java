// Exports the user's GTA2 Ghidra annotations to grep-able text files.
// Run through re/tools/export.sh (analyzeHeadless -postScript ExportGta2Re.java <outdir>).
//@category GTA2

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.*;
import ghidra.program.model.data.*;
import ghidra.program.model.data.Enum;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.*;

public class ExportGta2Re extends GhidraScript {

	// Types Ghidra creates by itself while importing/analyzing a PE.
	private static final Set<String> AUTO_CATEGORIES =
		Set.of("/PE", "/DOS", "/PDB", "/Demangler");

	private File outDir;
	private final Map<String, Integer> stats = new LinkedHashMap<>();

	@Override
	public void run() throws Exception {
		outDir = new File(getScriptArgs()[0]);
		outDir.mkdirs();

		exportFunctions();
		exportGlobals();
		exportImports();
		exportComments();
		List<DataType> types = collectUserTypes();
		exportCHeader(types);
		exportNasmTypes(types);
		// Last: it renames colliding types (g2_ prefix), so it gets fresh name maps.
		c64 = true;
		cNames.clear();
		cNamesUsed.clear();
		builtinsUsed.clear();
		builtinSizes.clear();
		exportCHeader(types);
		c64 = false;
		exportStats();
		if (getScriptArgs().length > 1) {
			dumpBlocks(new File(getScriptArgs()[1], "blocks"));
		}
	}

	/** Raw bytes of every initialized block, for tools/check_mapping.py. */
	private void dumpBlocks(File dir) throws Exception {
		dir.mkdirs();
		for (MemoryBlock b : currentProgram.getMemory().getBlocks()) {
			if (!b.isInitialized()) {
				continue;
			}
			byte[] buf = new byte[(int) b.getSize()];
			b.getBytes(b.getStart(), buf);
			try (FileOutputStream f = new FileOutputStream(new File(dir, b.getStart() + ".bin"))) {
				f.write(buf);
			}
		}
	}

	// ---------------------------------------------------------------- helpers

	private static boolean isUserNamed(Symbol s) {
		SourceType src = s.getSource();
		return src != SourceType.DEFAULT && !s.isDynamic();
	}

	private static String hex(Address a) {
		return "0x" + a.toString();
	}

	private static String csv(Object o) {
		String s = o == null ? "" : o.toString();
		if (s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r")) {
			return "\"" + s.replace("\"", "\"\"") + "\"";
		}
		return s;
	}

	private static String row(Object... cols) {
		StringBuilder sb = new StringBuilder();
		for (int i = 0; i < cols.length; i++) {
			if (i > 0) {
				sb.append(',');
			}
			sb.append(csv(cols[i]));
		}
		return sb.append('\n').toString();
	}

	private PrintWriter open(String name) throws IOException {
		return new PrintWriter(new BufferedWriter(new OutputStreamWriter(
			new FileOutputStream(new File(outDir, name)), StandardCharsets.UTF_8)));
	}

	private void count(String key) {
		stats.merge(key, 1, Integer::sum);
	}

	private String section(Address a) {
		MemoryBlock b = currentProgram.getMemory().getBlock(a);
		return b == null ? "" : b.getName();
	}

	/** NASM identifier: [A-Za-z0-9_], not starting with a digit. */
	private static String ident(String s) {
		String r = s.replace("::", "__").replaceAll("[^A-Za-z0-9_]", "_");
		if (r.isEmpty() || Character.isDigit(r.charAt(0))) {
			r = "_" + r;
		}
		return r;
	}

	private static String oneLine(String s) {
		// "*/" inside a Ghidra comment would close the C comment it is exported into
		return s == null ? "" : s.replaceAll("\\s+", " ").replace("*/", "* /").trim();
	}

	// -------------------------------------------------------------- functions

	private void exportFunctions() throws IOException {
		List<String[]> incLines = new ArrayList<>();
		try (PrintWriter named = open("functions.csv");
				PrintWriter unnamed = open("functions_typed_unnamed.csv")) {
			String header = row("address", "name", "namespace", "name_source", "calling_convention",
				"signature_source", "size", "thunk_to", "signature");
			named.print(header);
			unnamed.print(header);
			for (Function f : currentProgram.getFunctionManager().getFunctions(true)) {
				Symbol s = f.getSymbol();
				boolean isNamed = isUserNamed(s);
				// A thunk takes its target's name with source DEFAULT: count it apart so
				// default_named stays the real FUN_ count.
				boolean namedThunk = !isNamed && f.isThunk() && f.getThunkedFunction(true) != null
					&& !f.getThunkedFunction(true).getName().startsWith("FUN_");
				count(isNamed ? "functions.named"
						: namedThunk ? "functions.thunk_named" : "functions.default_named");
				boolean typed = f.getSignatureSource() == SourceType.USER_DEFINED;
				if (!isNamed && !typed) {
					continue;
				}
				if (isNamed) {
					count("functions.named." + s.getSource());
				}
				else {
					count("functions.default_named.user_signature");
				}
				Function thunked = f.isThunk() ? f.getThunkedFunction(false) : null;
				String line = row(hex(f.getEntryPoint()), f.getName(),
					f.getParentNamespace().isGlobal() ? "" : f.getParentNamespace().getName(true),
					s.getSource(), f.getCallingConventionName(), f.getSignatureSource(),
					f.getBody().getNumAddresses(), thunked == null ? "" : thunked.getName(true),
					f.getPrototypeString(false, true));
				(isNamed ? named : unnamed).print(line);
				if (isNamed) {
					incLines.add(new String[] { "fn_" + ident(s.getName(true)),
						hex(f.getEntryPoint()), oneLine(f.getPrototypeString(false, true)) });
				}
			}
		}
		pendingInc.put("functions", incLines);
	}

	// ---------------------------------------------------------------- globals

	private void exportGlobals() throws IOException {
		List<String[]> incLines = new ArrayList<>();
		Listing listing = currentProgram.getListing();
		try (PrintWriter w = open("globals.csv")) {
			w.print(row("address", "name", "namespace", "name_source", "section", "in_function",
				"datatype", "size"));
			for (Symbol s : currentProgram.getSymbolTable().getAllSymbols(false)) {
				if (s.getSymbolType() != SymbolType.LABEL || s.isExternal()) {
					continue;
				}
				Address a = s.getAddress();
				if (!a.isMemoryAddress()) {
					continue;
				}
				if (!isUserNamed(s)) {
					continue;
				}
				count("labels.named." + s.getSource());
				// Analysis labels are strings, switch tables, import thunks etc.
				if (s.getSource() == SourceType.ANALYSIS) {
					continue;
				}
				Data d = listing.getDataAt(a);
				Function fn = currentProgram.getFunctionManager().getFunctionContaining(a);
				w.print(row(hex(a), s.getName(), s.getParentNamespace().isGlobal() ? ""
						: s.getParentNamespace().getName(true),
					s.getSource(), section(a), fn == null ? "" : fn.getName(true),
					d == null ? "" : d.getDataType().getPathName(), d == null ? "" : d.getLength()));
				count("globals.exported");
				String type = d == null ? "" : d.getDataType().getDisplayName() + " (" +
					d.getLength() + " bytes)";
				// Globals already named g_* in Ghidra keep their name instead of becoming g_g_*.
				String id = ident(s.getName(true));
				incLines.add(new String[] { fn != null ? "lbl_" + id : id.startsWith("g_") ? id : "g_" + id, hex(a),
					fn == null ? type : "label in " + fn.getName(true) });
			}
		}
		for (Symbol s : currentProgram.getSymbolTable().getAllSymbols(true)) {
			if (s.getSymbolType() == SymbolType.LABEL && s.getSource() == SourceType.DEFAULT) {
				count("labels.default_named");
			}
		}
		// Default-named globals that the user gave a real type to: DAT_ names, but typed.
		try (PrintWriter w = open("globals_typed_unnamed.csv")) {
			w.print(row("address", "name", "section", "datatype", "size"));
			DataIterator it = listing.getDefinedData(true);
			while (it.hasNext() && !monitor.isCancelled()) {
				Data d = it.next();
				Symbol s = d.getPrimarySymbol();
				if (s == null || isUserNamed(s)) {
					continue;
				}
				DataType dt = d.getDataType();
				if (!isUserType(dt)) {
					continue;
				}
				count("globals.default_named.user_type");
				w.print(row(hex(d.getAddress()), s.getName(), section(d.getAddress()),
					dt.getPathName(), d.getLength()));
			}
		}
		pendingInc.put("globals", incLines);
	}

	private boolean isUserType(DataType dt) {
		while (dt instanceof Pointer || dt instanceof Array || dt instanceof TypeDef) {
			if (dt instanceof TypeDef && isUserCategory(dt)) {
				return true;
			}
			dt = dt instanceof Pointer ? ((Pointer) dt).getDataType()
					: dt instanceof Array ? ((Array) dt).getDataType()
							: ((TypeDef) dt).getDataType();
			if (dt == null) {
				return false;
			}
		}
		return (dt instanceof Composite || dt instanceof Enum) && isUserCategory(dt);
	}

	// ---------------------------------------------------------------- imports

	private void exportImports() throws IOException {
		ReferenceManager rm = currentProgram.getReferenceManager();
		try (PrintWriter w = open("imports.csv")) {
			w.print(row("iat_address", "dll", "name", "ordinal"));
			SymbolIterator it = currentProgram.getSymbolTable().getExternalSymbols();
			List<String[]> rows = new ArrayList<>();
			while (it.hasNext()) {
				Symbol s = it.next();
				if (s.getSymbolType() != SymbolType.FUNCTION && s.getSymbolType() != SymbolType.LABEL) {
					continue;
				}
				ExternalLocation loc =
					currentProgram.getExternalManager().getExternalLocation(s);
				String dll = s.getParentNamespace().getName();
				String ord = loc != null && loc.getOriginalImportedName() != null
						? loc.getOriginalImportedName() : "";
				boolean any = false;
				for (Reference r : rm.getReferencesTo(s.getAddress())) {
					Address from = r.getFromAddress();
					// IAT slots are data, not the call sites of thunks.
					if (listing().getInstructionAt(from) != null) {
						continue;
					}
					rows.add(new String[] { hex(from), dll, s.getName(), ord });
					any = true;
				}
				if (!any) {
					rows.add(new String[] { "", dll, s.getName(), ord });
				}
				count("imports");
			}
			rows.sort(Comparator.comparing((String[] r) -> r[0]).thenComparing(r -> r[2]));
			for (String[] r : rows) {
				w.print(row((Object[]) r));
			}
		}
	}

	private Listing listing() {
		return currentProgram.getListing();
	}

	// --------------------------------------------------------------- comments

	private void exportComments() throws IOException {
		int[] kinds = { CodeUnit.PLATE_COMMENT, CodeUnit.PRE_COMMENT, CodeUnit.EOL_COMMENT,
			CodeUnit.POST_COMMENT, CodeUnit.REPEATABLE_COMMENT };
		String[] names = { "plate", "pre", "eol", "post", "repeatable" };
		Listing l = listing();
		try (PrintWriter w = open("comments.csv")) {
			w.print(row("address", "kind", "function", "comment"));
			AddressIterator it =
				l.getCommentAddressIterator(currentProgram.getMemory(), true);
			while (it.hasNext()) {
				Address a = it.next();
				// Section-name comments the PE loader puts on the headers.
				if (section(a).equals("Headers")) {
					continue;
				}
				Function fn = currentProgram.getFunctionManager().getFunctionContaining(a);
				for (int i = 0; i < kinds.length; i++) {
					String c = l.getComment(kinds[i], a);
					if (c == null || c.isBlank()) {
						continue;
					}
					count("comments");
					w.print(row(hex(a), names[i], fn == null ? "" : fn.getName(true), c));
				}
			}
		}
	}

	// ------------------------------------------------------------------ types

	private boolean isUserCategory(DataType dt) {
		SourceArchive sa = dt.getSourceArchive();
		if (sa == null || sa.getArchiveType() != ArchiveType.PROGRAM) {
			return false;
		}
		String cat = dt.getCategoryPath().getPath();
		for (String auto : AUTO_CATEGORIES) {
			if (cat.equals(auto) || cat.startsWith(auto + "/")) {
				return false;
			}
		}
		// Windows API function definitions pulled in from the type archive.
		return !cat.endsWith("/functions");
	}

	private List<DataType> collectUserTypes() {
		List<DataType> out = new ArrayList<>();
		Iterator<DataType> it = currentProgram.getDataTypeManager().getAllDataTypes();
		while (it.hasNext()) {
			DataType dt = it.next();
			if (dt instanceof Pointer || dt instanceof Array || dt instanceof BuiltInDataType) {
				continue;
			}
			if (!isUserCategory(dt)) {
				continue;
			}
			out.add(dt);
			count("types." + kind(dt));
		}
		out.sort(Comparator.comparing(DataType::getPathName));
		return out;
	}

	private static String kind(DataType dt) {
		if (dt instanceof Structure) {
			return "struct";
		}
		if (dt instanceof Union) {
			return "union";
		}
		if (dt instanceof Enum) {
			return "enum";
		}
		if (dt instanceof TypeDef) {
			return "typedef";
		}
		if (dt instanceof FunctionDefinition) {
			return "funcdef";
		}
		return dt.getClass().getSimpleName();
	}

	// ---------------------------------------------------------------- C header
	//
	// Ghidra's DataTypeWriter spells every undefined byte as its own field (a placeholder
	// class alone turns into millions of lines), so the header is written here instead:
	// explicit gaps, packed layout, offset on every line. A companion check file asserts
	// sizeof/offsetof of everything against Ghidra's numbers.

	private static final Set<String> C_KEYWORDS = Set.of("auto", "break", "case", "char",
		"const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for",
		"goto", "if", "int", "long", "register", "return", "short", "signed", "sizeof", "static",
		"struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "inline",
		"restrict", "bool", "true", "false");

	// Ghidra built-in names -> C spelling (32-bit Windows layout).
	private static final Map<String, String> BUILTINS = new LinkedHashMap<>();
	static {
		String[][] m = { { "undefined", "uint8_t" }, { "undefined1", "uint8_t" },
			{ "undefined2", "uint16_t" }, { "undefined4", "uint32_t" },
			{ "undefined8", "uint64_t" }, { "byte", "uint8_t" }, { "sbyte", "int8_t" },
			{ "word", "uint16_t" }, { "dword", "uint32_t" }, { "qword", "uint64_t" },
			{ "uchar", "uint8_t" }, { "schar", "int8_t" }, { "ushort", "uint16_t" },
			{ "uint", "uint32_t" }, { "ulong", "uint32_t" }, { "longlong", "int64_t" },
			{ "ulonglong", "uint64_t" }, { "bool_", "uint8_t" }, { "wchar_t", "uint16_t" },
			{ "wchar16", "uint16_t" }, { "pointer", "void *" }, { "pointer32", "uint32_t" },
			{ "ImageBaseOffset32", "uint32_t" } };
		for (String[] e : m) {
			BUILTINS.put(e[0], e[1]);
		}
	}
	private static final Map<String, Integer> C_SIZES = Map.of("uint8_t", 1, "int8_t", 1,
		"uint16_t", 2, "uint32_t", 4, "int64_t", 8, "uint64_t", 8, "void *", 4);
	private static final Set<String> NATIVE_C =
		Set.of("char", "short", "int", "long", "float", "double", "void");

	// gta2_types_c64.h: the same layout for 64-bit host C, where a game pointer is 4 bytes but a
	// C pointer is 8. Every pointer becomes uint32_t with the pointee in a comment.
	private boolean c64;
	// Names a host C module gets from libc headers; Ghidra types with these names get g2_, in
	// both headers.
	private static final Set<String> LIBC_NAMES = Set.of("size_t", "ssize_t", "ptrdiff_t",
		"wchar_t", "wint_t", "intptr_t", "uintptr_t", "time_t", "clock_t", "off_t", "fpos_t",
		"FILE", "va_list", "bool", "uint", "ushort", "ulong", "u_int", "u_char", "u_short",
		"u_long", "div_t", "ldiv_t", "tm", "timeval", "timespec", "max_align_t", "mbstate_t",
		"jmp_buf", "sig_atomic_t", "errno_t", "dev_t", "mode_t", "pid_t", "id_t", "key_t");
	private int checkSeq;

	private final Map<DataType, String> cNames = new LinkedHashMap<>();
	private final Set<String> cNamesUsed = new HashSet<>();
	private final Set<String> builtinsUsed = new TreeSet<>();
	private final Map<String, Integer> builtinSizes = new HashMap<>();

	private static String cIdent(String s) {
		String r = ident(s);
		return C_KEYWORDS.contains(r) ? r + "_" : r;
	}

	/** Unique C/NASM name of a named (non-pointer, non-array) type. */
	private String cName(DataType dt) {
		String n = cNames.get(dt);
		if (n != null) {
			return n;
		}
		n = cIdent(dt.getName());
		if (LIBC_NAMES.contains(n)) {
			n = "g2_" + n;
		}
		if (BUILTINS.containsKey(n) || NATIVE_C.contains(n) || !cNamesUsed.add(n)) {
			n = cIdent(dt.getCategoryPath().getPath() + "_" + dt.getName());
			for (int i = 2; !cNamesUsed.add(n); i++) {
				n = n + "_" + i;
			}
		}
		cNames.put(dt, n);
		return n;
	}

	/** C declarator for `name` of type dt, e.g. `Car *(*name)[4]`. */
	private String decl(DataType dt, String name) {
		if (dt == null) {
			return "void " + name;
		}
		if (dt instanceof Pointer && c64) {
			c64 = false;
			String pointee = decl(dt, "").trim();
			c64 = true;
			return "uint32_t /* " + pointee + " */" + (name.isEmpty() ? "" : " " + name);
		}
		if (dt instanceof Pointer) {
			DataType t = ((Pointer) dt).getDataType();
			boolean paren = t instanceof Array || t instanceof FunctionDefinition;
			return decl(t, paren ? "(*" + name + ")" : "*" + name);
		}
		if (dt instanceof Array) {
			Array a = (Array) dt;
			return decl(a.getDataType(), name + "[" + a.getNumElements() + "]");
		}
		if (dt instanceof BitFieldDataType) {
			BitFieldDataType bf = (BitFieldDataType) dt;
			return decl(bf.getBaseDataType(), name) + " : " + bf.getBitSize();
		}
		return typeRef(dt) + (name.isEmpty() ? "" : " " + name);
	}

	private String typeRef(DataType dt) {
		if (dt instanceof Composite || dt instanceof Enum || dt instanceof TypeDef ||
			dt instanceof FunctionDefinition) {
			return cName(dt);
		}
		String n = dt.getName();
		if (NATIVE_C.contains(n)) {
			return n.equals("long") ? "int32_t" : n;
		}
		if (n.equals("ulong")) {
			return "uint32_t";
		}
		String id = cIdent(n);
		if (c64 || LIBC_NAMES.contains(id)) {
			// Spell built-ins as stdint types: their Ghidra names (uint, wchar_t...) clash with libc
			// (wchar_t is int on i386 ELF). gta2_types.h keeps the rest for readability.
			String c = BUILTINS.get(id);
			if (c != null && !c.equals("void *") && C_SIZES.getOrDefault(c, -1) == dt.getLength()) {
				return c;
			}
			id = "g2_" + id;
		}
		builtinsUsed.add(id);
		builtinSizes.put(id, dt.getLength());
		return id;
	}

	/** Collects dt and every named type it references. */
	private void collectDeps(DataType dt, Set<DataType> out) {
		while (dt instanceof Pointer || dt instanceof Array || dt instanceof BitFieldDataType) {
			dt = dt instanceof Pointer ? ((Pointer) dt).getDataType()
					: dt instanceof Array ? ((Array) dt).getDataType()
							: ((BitFieldDataType) dt).getBaseDataType();
		}
		if (dt == null || !(dt instanceof Composite || dt instanceof Enum ||
			dt instanceof TypeDef || dt instanceof FunctionDefinition) || !out.add(dt)) {
			return;
		}
		if (dt instanceof Composite) {
			for (DataTypeComponent c : ((Composite) dt).getDefinedComponents()) {
				collectDeps(c.getDataType(), out);
			}
		}
		else if (dt instanceof TypeDef) {
			collectDeps(((TypeDef) dt).getDataType(), out);
		}
		else if (dt instanceof FunctionDefinition) {
			FunctionDefinition f = (FunctionDefinition) dt;
			collectDeps(f.getReturnType(), out);
			for (ParameterDefinition p : f.getArguments()) {
				collectDeps(p.getDataType(), out);
			}
		}
	}

	/** Types that must be complete before dt (by-value members, typedef targets). */
	private List<DataType> valueDeps(DataType dt) {
		List<DataType> deps = new ArrayList<>();
		List<DataType> roots = new ArrayList<>();
		if (dt instanceof Composite) {
			for (DataTypeComponent c : ((Composite) dt).getDefinedComponents()) {
				roots.add(c.getDataType());
			}
		}
		else if (dt instanceof TypeDef) {
			roots.add(((TypeDef) dt).getDataType());
		}
		for (DataType r : roots) {
			while (r instanceof Array || r instanceof BitFieldDataType) {
				r = r instanceof Array ? ((Array) r).getDataType()
						: ((BitFieldDataType) r).getBaseDataType();
			}
			if (r instanceof Composite || r instanceof TypeDef || r instanceof Enum) {
				deps.add(r);
			}
		}
		return deps;
	}

	private void orderTypes(DataType dt, Set<DataType> all, Set<DataType> done,
			Set<DataType> visiting, List<DataType> out) {
		if (done.contains(dt) || !all.contains(dt) || !visiting.add(dt)) {
			return;
		}
		for (DataType d : valueDeps(dt)) {
			orderTypes(d, all, done, visiting, out);
		}
		visiting.remove(dt);
		done.add(dt);
		out.add(dt);
	}

	/** Typedefs and function types referenced (at any pointer depth) by an alias. */
	private void aliasRefs(DataType dt, List<DataType> out) {
		while (dt instanceof Pointer || dt instanceof Array) {
			dt = dt instanceof Pointer ? ((Pointer) dt).getDataType() : ((Array) dt).getDataType();
		}
		if (dt instanceof TypeDef || dt instanceof FunctionDefinition) {
			out.add(dt);
		}
	}

	private void orderAliases(DataType dt, Set<DataType> all, Set<DataType> done,
			Set<DataType> visiting, List<DataType> out) {
		if (!(dt instanceof TypeDef || dt instanceof FunctionDefinition) || done.contains(dt) ||
			!all.contains(dt) || !visiting.add(dt)) {
			return;
		}
		List<DataType> refs = new ArrayList<>();
		if (dt instanceof TypeDef) {
			aliasRefs(((TypeDef) dt).getDataType(), refs);
		}
		else {
			FunctionDefinition f = (FunctionDefinition) dt;
			aliasRefs(f.getReturnType(), refs);
			for (ParameterDefinition p : f.getArguments()) {
				aliasRefs(p.getDataType(), refs);
			}
		}
		for (DataType r : refs) {
			orderAliases(r, all, done, visiting, out);
		}
		visiting.remove(dt);
		done.add(dt);
		out.add(dt);
	}

	private void exportCHeader(List<DataType> types) throws Exception {
		Set<DataType> all = new LinkedHashSet<>();
		for (DataType dt : types) {
			collectDeps(dt, all);
		}
		Set<DataType> user = new HashSet<>(types);
		// Name user types first so they keep their plain names on collisions.
		types.forEach(this::cName);
		all.forEach(this::cName);

		List<DataType> ordered = new ArrayList<>();
		Set<DataType> done = new HashSet<>();
		List<DataType> sorted = new ArrayList<>(all);
		sorted.sort(Comparator.comparing(DataType::getPathName));
		for (DataType dt : sorted) {
			orderTypes(dt, all, done, new HashSet<>(), ordered);
		}

		StringBuilder body = new StringBuilder();
		StringBuilder check = new StringBuilder();
		Set<String> enumConsts = new HashSet<>();

		body.append("\n/* ---- forward declarations */\n");
		for (DataType dt : sorted) {
			if (dt instanceof Composite) {
				String kw = dt instanceof Union ? "union" : "struct";
				body.append("typedef ").append(kw).append(' ').append(cName(dt)).append(' ')
						.append(cName(dt)).append(";\n");
			}
		}
		body.append("\n/* ---- enums (stored as fixed-size integers to keep layout) */\n");
		for (DataType dt : sorted) {
			if (dt instanceof Enum) {
				writeCEnum(body, (Enum) dt, enumConsts);
			}
		}
		body.append("\n/* ---- typedefs and function types */\n");
		List<DataType> aliases = new ArrayList<>();
		Set<DataType> aliasDone = new HashSet<>();
		for (DataType dt : sorted) {
			orderAliases(dt, all, aliasDone, new HashSet<>(), aliases);
		}
		for (DataType dt : aliases) {
			if (c64 && (dt instanceof FunctionDefinition ||
				dt instanceof TypeDef && ((TypeDef) dt).getDataType() instanceof FunctionDefinition)) {
				// Only ever reached through a pointer, which is uint32_t here; and x86-64 clang
				// rejects __thiscall/__stdcall under -Werror.
				body.append("/* function type ").append(cName(dt)).append(" omitted */\n");
				continue;
			}
			if (dt instanceof FunctionDefinition) {
				FunctionDefinition f = (FunctionDefinition) dt;
				body.append("typedef ").append(funcDecl(f, cName(f))).append(";\n");
			}
			else {
				body.append("typedef ").append(decl(((TypeDef) dt).getDataType(), cName(dt)))
						.append(";\n");
			}
		}
		body.append("\n/* ---- composites, dependency order */\n");
		for (DataType dt : ordered) {
			if (dt instanceof Composite) {
				writeCComposite(body, check, (Composite) dt, user.contains(dt));
			}
		}

		try (PrintWriter w = open(c64 ? "gta2_types_c64.h" : "gta2_types.h")) {
			w.println("// Generated by re/tools/ExportGta2Re.java from Ghidra program " +
				currentProgram.getName() + ". Do not edit by hand.");
			w.println("// User-defined Ghidra types plus everything they reference. Layout is");
			w.println("// explicit (packed, gaps spelled out) and matches 32-bit gta2.exe; every");
			if (c64) {
				w.println("// member carries its offset. This variant is for 64-bit host C (C99):");
				w.println("// every game pointer is a uint32_t with the pointee type in a comment,");
				w.println("// built-in Ghidra names are spelled as stdint types, and types whose name");
				w.println("// clashes with libc (wchar_t, ptrdiff_t, uint...) carry a g2_ prefix.");
				w.println("// Read a pointer field with GP(Type, s->field). Function types are omitted.");
				w.println("#ifndef GTA2_TYPES_C64_H");
				w.println("#define GTA2_TYPES_C64_H");
				w.println("#include <stdint.h>");
				w.println();
				w.println("#ifndef GP");
				w.println("#define GP(T, v) ((T *)(uintptr_t)(uint32_t)(v))");
				w.println("#endif");
			}
			else {
				w.println("// member carries its offset. Checked with clang for i686-windows, i386 ELF");
				w.println("// (-std=c99 -ffreestanding) and i386 Darwin (-m32).");
				w.println("#pragma once");
				w.println("#include <stdint.h>");
				w.println();
				w.println("// Calling conventions of function types; empty where the target lacks them.");
				w.println("#if defined(_MSC_VER) || (defined(__i386__) && !defined(__APPLE__))");
				w.println("#define G2_CDECL __cdecl");
				w.println("#define G2_STDCALL __stdcall");
				w.println("#define G2_FASTCALL __fastcall");
				w.println("#define G2_THISCALL __thiscall");
				w.println("#else");
				w.println("#define G2_CDECL");
				w.println("#define G2_STDCALL");
				w.println("#define G2_FASTCALL");
				w.println("#define G2_THISCALL");
				w.println("#endif");
			}
			w.println();
			w.println("/* ---- Ghidra built-in type names */");
			for (String b : builtinsUsed) {
				if (c64 && !b.startsWith("g2_")) {
					continue; // registered by the pointee comments, which use the 32-bit spelling
				}
				String c = BUILTINS.get(b);
				int size = builtinSizes.get(b);
				// Ghidra's int16/uint16 etc. are 16-BYTE integers; never trust the name.
				if (c == null || C_SIZES.getOrDefault(c, -1) != size) {
					c = "uint8_t";
					b = b + "[" + Math.max(1, builtinSizes.get(b)) + "]";
				}
				w.println("typedef " + c + " " + b + ";" +
					(BUILTINS.containsKey(b.replaceAll("\\[.*", "")) ? "" : " // Ghidra built-in, " + size + " bytes"));
			}
			w.println();
			w.println("#pragma pack(push, 1)");
			w.print(body);
			w.println();
			w.println("#pragma pack(pop)");
			if (c64) {
				w.println("#endif");
			}
		}
		File check_c = new File(getScriptArgs().length > 1 ? getScriptArgs()[1] : outDir.getPath(),
			c64 ? "gta2_types_c64_check.c" : "gta2_types_check.c");
		try (PrintWriter w = new PrintWriter(check_c, StandardCharsets.UTF_8)) {
			if (c64) {
				w.println("// Generated layout check: clang -arch x86_64 -std=c99 -Werror -fsyntax-only");
				// libc first: the header must coexist with what a host C module includes.
				w.println("#include <stddef.h>");
				w.println("#include <stdio.h>");
				w.println("#include <stdlib.h>");
				w.println("#include <string.h>");
				w.println("#include <sys/types.h>");
				w.println("#include \"gta2_types_c64.h\"");
				w.println("typedef char g2chk_ptr[sizeof(GP(int, 0)) == sizeof(void *) ? 1 : -1];");
			}
			else {
				w.println("// Generated layout check: clang -m32 -fsyntax-only gta2_types_check.c");
				w.println("#include <stddef.h>");
				w.println("#include \"gta2_types.h\"");
			}
			w.print(check);
		}
	}

	/** One compile-time check: C11 _Static_assert, or the C99 negative-array idiom for c64. */
	private String layoutCheck(String cond, String what) {
		if (c64) {
			return String.format("typedef char g2chk_%d[(%s) ? 1 : -1]; /* %s */%n", checkSeq++,
				cond, what);
		}
		return String.format("_Static_assert(%s, \"%s\");%n", cond, what);
	}

	private String funcDecl(FunctionDefinition f, String name) {
		StringBuilder args = new StringBuilder();
		ParameterDefinition[] ps = f.getArguments();
		for (int i = 0; i < ps.length; i++) {
			if (i > 0) {
				args.append(", ");
			}
			String pn = ps[i].getName();
			args.append(decl(ps[i].getDataType(), pn == null || pn.isBlank() ? "p" + i : cIdent(pn)));
		}
		if (f.hasVarArgs()) {
			args.append(ps.length > 0 ? ", ..." : "...");
		}
		if (args.length() == 0) {
			args.append("void");
		}
		String cc = f.getCallingConventionName();
		// Through macros: i386 Darwin (clang -m32 on macOS) rejects __fastcall/__thiscall.
		String ccs = cc != null && cc.startsWith("__") ? "G2_" + cc.substring(2).toUpperCase() + " " : "";
		return decl(f.getReturnType(), ccs + name + "(" + args + ")");
	}

	private void writeCEnum(StringBuilder b, Enum e, Set<String> used) {
		String name = cName(e);
		String storage = switch (e.getLength()) {
			case 1 -> "uint8_t";
			case 2 -> "uint16_t";
			case 8 -> "uint64_t";
			default -> "uint32_t";
		};
		b.append("\n// ").append(e.getPathName()).append('\n');
		b.append("typedef ").append(storage).append(' ').append(name).append(";\n");
		b.append("enum ").append(name).append("_values {\n");
		long[] values = e.getValues();
		Arrays.sort(values);
		for (long v : values) {
			for (String n : e.getNames(v)) {
				String id = cIdent(n);
				// Reserved identifiers (_MSC_VER, _M_IX86...) collide with compiler macros.
				if (id.matches("_[A-Z_].*") || !used.add(id)) {
					id = name + "__" + id;
					if (!used.add(id)) {
						continue;
					}
				}
				b.append("    ").append(id).append(" = ").append(v).append(",\n");
			}
		}
		b.append("};\n");
	}

	private void writeCComposite(StringBuilder b, StringBuilder check, Composite c,
			boolean isUser) {
		String name = cName(c);
		boolean union = c instanceof Union;
		b.append("\n// ").append(c.getPathName()).append(isUser ? "" : "  (dependency)")
				.append(String.format("  size 0x%x%n", c.getLength()));
		if (c.getDescription() != null && !c.getDescription().isBlank()) {
			b.append("// ").append(oneLine(c.getDescription())).append('\n');
		}
		b.append(union ? "union " : "struct ").append(name).append(" {\n");
		check.append(layoutCheck(String.format("sizeof(%s) == 0x%x", name, c.getLength()),
			name + " size"));
		int pos = 0;
		int gap = 0;
		Set<String> seen = new HashSet<>();
		DataTypeComponent[] comps = c.getDefinedComponents();
		for (int i = 0; i < comps.length; i++) {
			DataTypeComponent comp = comps[i];
			int off = comp.getOffset();
			int len = comp.getLength();
			String fn = cIdent(fieldName(comp, seen));
			if (!union && off > pos) {
				b.append(String.format("    uint8_t _gap_0x%x[0x%x];%n", pos, off - pos));
				gap++;
			}
			String comment = comp.getComment() == null ? "" : " " + oneLine(comp.getComment());
			if (comp.isBitFieldComponent()) {
				// Bitfields are emitted as a raw storage unit: C packing rules for bitfields
				// differ between compilers, the byte layout must not.
				if (!union && off < pos) {
					b.append(String.format("    /* 0x%x %s */%n", off,
						oneLine(decl(comp.getDataType(), fn)) + comment));
					continue;
				}
				int unitEnd = off + len;
				StringBuilder bits = new StringBuilder(decl(comp.getDataType(), fn));
				while (!union && i + 1 < comps.length && comps[i + 1].isBitFieldComponent() &&
					comps[i + 1].getOffset() < unitEnd + 0) {
					DataTypeComponent n = comps[++i];
					unitEnd = Math.max(unitEnd, n.getOffset() + n.getLength());
					bits.append("; ").append(decl(n.getDataType(), cIdent(fieldName(n, seen))));
				}
				b.append(String.format("    uint8_t %s_bits[%d]; /* 0x%x bitfields: %s */%n", fn,
					unitEnd - off, off, oneLine(bits.toString())));
				pos = unitEnd;
				continue;
			}
			if (len == 0 || comp.getDataType().getLength() <= 0) {
				b.append(String.format("    /* 0x%x %s (zero-length) */%n", off,
					decl(comp.getDataType(), fn)));
				continue;
			}
			if (!union && off < pos) {
				b.append(String.format("    /* 0x%x overlaps: %s */%n", off,
					decl(comp.getDataType(), fn)));
				continue;
			}
			b.append(String.format("    %s; /* 0x%x%s */%n", decl(comp.getDataType(), fn), off,
				comment));
			if (!union) {
				check.append(layoutCheck(String.format("offsetof(%s, %s) == 0x%x", name, fn, off),
					name + "." + fn));
				pos = off + len;
			}
		}
		if (!union && c.getLength() > pos && !c.isZeroLength()) {
			b.append(String.format("    uint8_t _gap_0x%x[0x%x];%n", pos, c.getLength() - pos));
		}
		if (union && comps.length == 0 || !union && comps.length == 0 && c.getLength() == 0) {
			b.append("    uint8_t _empty;\n");
		}
		b.append("};\n");
	}

	private void exportNasmTypes(List<DataType> types) throws IOException {
		try (PrintWriter w = open("gta2_types.inc")) {
			w.println("; Generated by re/tools/ExportGta2Re.java from Ghidra program " +
				currentProgram.getName() + ". Do not edit by hand.");
			w.println("; Structs as NASM struc (Name.field = offset, Name_size = size),");
			w.println("; unions as Name.member equ 0, enums as Enum.VALUE equ n.");
			w.println("%ifndef GTA2_TYPES_INC");
			w.println("%define GTA2_TYPES_INC");
			for (DataType dt : types) {
				String name = cName(dt);
				if (dt instanceof Structure) {
					writeStruc(w, name, (Structure) dt);
				}
				else if (dt instanceof Union) {
					writeUnion(w, name, (Union) dt);
				}
				else if (dt instanceof Enum) {
					writeEnum(w, name, (Enum) dt);
				}
			}
			w.println();
			w.println("%endif");
		}
		File check = new File(getScriptArgs().length > 1 ? getScriptArgs()[1] : outDir.getPath(),
			"gta2_types_check.asm");
		try (PrintWriter w = new PrintWriter(check, StandardCharsets.UTF_8)) {
			w.println("%include \"gta2_addresses.inc\"");
			w.println("%include \"gta2_types.inc\"");
			w.print(nasmCheck);
		}
	}

	private static String fieldName(DataTypeComponent c, Set<String> seen) {
		String n = c.getFieldName();
		if (n == null || n.isBlank()) {
			n = c.getDefaultFieldName();
		}
		n = ident(n);
		String base = n;
		for (int i = 2; !seen.add(n); i++) {
			n = base + "_" + i;
		}
		return n;
	}

	private final StringBuilder nasmCheck = new StringBuilder();

	private void nasmAssert(String expr, long value) {
		nasmCheck.append(String.format("%%if %s != %d%n  %%error \"%s\"%n%%endif%n", expr,
			value, expr));
	}

	private void writeStruc(PrintWriter w, String name, Structure s) {
		nasmAssert(name + "_size", s.getLength());
		w.println();
		w.printf("; %s  (%d bytes)%n", s.getPathName(), s.getLength());
		w.println("struc " + name);
		int pos = 0;
		Set<String> seen = new HashSet<>();
		for (DataTypeComponent c : s.getDefinedComponents()) {
			int off = c.getOffset();
			int len = c.getLength();
			String type = c.getDataType().getDisplayName();
			if (c.isBitFieldComponent()) {
				BitFieldDataType bf = (BitFieldDataType) c.getDataType();
				type = String.format("bitfield %s:%d @bit %d", bf.getBaseDataType().getDisplayName(),
					bf.getBitSize(), bf.getBitOffset());
			}
			if (off < pos) {
				// Overlapping storage (bitfields sharing a byte): offset only.
				w.printf("    ; .%s overlaps at 0x%x: %s%n", fieldName(c, seen), off, type);
				continue;
			}
			if (off > pos) {
				w.printf("    resb %d%n", off - pos);
			}
			if (len == 0) {
				w.printf("    .%s: ; 0x%x %s (zero-length)%n", fieldName(c, seen), off, type);
				continue;
			}
			String fname = fieldName(c, seen);
			nasmAssert(name + "." + fname, off);
			w.printf("    .%-32s resb %-6d ; 0x%x %s%n", fname, len, off, type);
			pos = off + len;
		}
		if (s.getLength() > pos) {
			w.printf("    resb %d%n", s.getLength() - pos);
		}
		w.println("endstruc");
	}

	private void writeUnion(PrintWriter w, String name, Union u) {
		w.println();
		w.printf("; union %s  (%d bytes)%n", u.getPathName(), u.getLength());
		Set<String> seen = new HashSet<>();
		for (DataTypeComponent c : u.getDefinedComponents()) {
			w.printf("%s.%s equ 0 ; %s (%d bytes)%n", name, fieldName(c, seen),
				c.getDataType().getDisplayName(), c.getLength());
		}
		w.printf("%s_size equ %d%n", name, u.getLength());
	}

	private void writeEnum(PrintWriter w, String name, Enum e) {
		w.println();
		w.printf("; enum %s  (%d bytes)%n", e.getPathName(), e.getLength());
		Set<String> seen = new HashSet<>();
		long[] values = e.getValues();
		Arrays.sort(values);
		for (long v : values) {
			for (String n : e.getNames(v)) {
				String id = ident(n);
				if (seen.add(id)) {
					w.printf("%s.%s equ %d%n", name, id, v);
				}
			}
		}
	}

	// ------------------------------------------------------------- addresses

	private final Map<String, List<String[]>> pendingInc = new LinkedHashMap<>();

	private void exportStats() throws IOException {
		try (PrintWriter w = open("gta2_addresses.inc")) {
			w.println("; Generated by re/tools/ExportGta2Re.java from Ghidra program " +
				currentProgram.getName() + ". Do not edit by hand.");
			w.println("; Absolute virtual addresses in vanilla gta2.exe (image base 0x" +
				currentProgram.getImageBase() + ").");
			w.println("%ifndef GTA2_ADDRESSES_INC");
			w.println("%define GTA2_ADDRESSES_INC");
			for (Map.Entry<String, List<String[]>> e : pendingInc.entrySet()) {
				w.println();
				w.println("; ---- " + e.getKey());
				Set<String> used = new HashSet<>();
				for (String[] l : e.getValue()) {
					String id = l[0];
					if (!used.add(id)) {
						id = id + "_" + l[1].substring(2);
						used.add(id);
					}
					w.printf("%-48s equ %s ; %s%n", id, l[1], l[2]);
				}
			}
			w.println();
			w.println("%endif");
		}
		try (PrintWriter w = open("stats.txt")) {
			w.println("program=" + currentProgram.getName());
			w.println("image_base=0x" + currentProgram.getImageBase());
			for (Map.Entry<String, Integer> e : stats.entrySet()) {
				w.println(e.getKey() + "=" + e.getValue());
			}
		}
	}
}
