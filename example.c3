// $ c3c compile-run hex.c3 examples/dump_bytes.c3
//
// Output:
// 00000000  09 20 63 33 20 69 73 20  67 72 65 61 74 21 20 0a  |. c3 is great! .|
//
import encoding::hex;
import std::io;

fn void main() {
	hex::dump_bytes("\t c3 is great! \n")!!;
}
