import source.utils;

void main()
{
	Random rng = new Random(12345);
	int: auto i = rng();  // Force type
	writeln("int: ", i);
}
