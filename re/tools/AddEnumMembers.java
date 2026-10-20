// Adds the enum constants that re/external/enums.csv marks NEW to enums that already exist
// in the current program. Only adds members: never renames, removes or resizes anything, and
// skips a constant whose name is already in the enum or whose value does not fit its size.
// Run from the CodeBrowser Script Manager and pick re/external/enums.csv when asked.
//@category GTA2

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.util.ArrayList;
import java.util.List;

import ghidra.app.script.GhidraScript;
import ghidra.program.model.data.DataType;
import ghidra.program.model.data.DataTypeManager;
import ghidra.program.model.data.Enum;

public class AddEnumMembers extends GhidraScript {

	@Override
	protected void run() throws Exception {
		File csv = askFile("re/external/enums.csv", "Add NEW members");
		DataTypeManager dtm = currentProgram.getDataTypeManager();
		int added = 0, skipped = 0;
		try (BufferedReader in = new BufferedReader(new FileReader(csv))) {
			String[] head = parse(in.readLine());
			int cEnum = idx(head, "enum"), cConst = idx(head, "constant"), cVal = idx(head, "value"),
				cStatus = idx(head, "status");
			String line;
			while ((line = in.readLine()) != null) {
				String[] f = parse(line);
				if (f.length <= cStatus || !f[cStatus].equals("NEW")) {
					continue;
				}
				Enum e = findEnum(dtm, f[cEnum]);
				if (e == null) {
					continue;
				}
				String name = f[cConst];
				long value = Long.parseLong(f[cVal]);
				long max = e.getLength() >= 8 ? Long.MAX_VALUE : (1L << (8 * e.getLength())) - 1;
				if (e.contains(name) || value < 0 || value > max) {
					skipped++;
					continue;
				}
				e.add(name, value);
				println("added " + e.getPathName() + "." + name + " = " + value);
				added++;
			}
		}
		println("added " + added + ", skipped " + skipped);
	}

	private Enum findEnum(DataTypeManager dtm, String name) {
		List<DataType> found = new ArrayList<>();
		dtm.findDataTypes(name, found);
		Enum hit = null;
		for (DataType dt : found) {
			if (dt instanceof Enum && dt.getName().equals(name)) {
				if (hit != null) {
					return null; // ambiguous: leave it to a human
				}
				hit = (Enum) dt;
			}
		}
		return hit;
	}

	private static int idx(String[] head, String col) {
		for (int i = 0; i < head.length; i++) {
			if (head[i].equals(col)) {
				return i;
			}
		}
		throw new IllegalArgumentException("no column " + col);
	}

	/** Minimal CSV split: handles quoted fields with commas and doubled quotes. */
	private static String[] parse(String line) {
		List<String> out = new ArrayList<>();
		StringBuilder cur = new StringBuilder();
		boolean q = false;
		for (int i = 0; i < line.length(); i++) {
			char c = line.charAt(i);
			if (q) {
				if (c == '"' && i + 1 < line.length() && line.charAt(i + 1) == '"') {
					cur.append('"');
					i++;
				}
				else if (c == '"') {
					q = false;
				}
				else {
					cur.append(c);
				}
			}
			else if (c == '"') {
				q = true;
			}
			else if (c == ',') {
				out.add(cur.toString());
				cur.setLength(0);
			}
			else {
				cur.append(c);
			}
		}
		out.add(cur.toString());
		return out.toArray(new String[0]);
	}
}
