import core.time;
import std.math;
import std.stdio;

class Random
{
	// Constants for SplitMix64 PRNG
	private static const long GOLDEN_RATIO = 0x9e3779b97f4a7c15;
	private static const long MULT_A = 0xbf58476d1ce4e5b9;
	private static const long MULT_B = 0x94d049bb133111eb;
	private static const long DOUBLE_EXPONENT_BITS = 1023L << 52;  // [1.0, 2.0) exponent
	private static const long MANTISSA_MASK = (1L << 52) - 1;  // 52 bits of mantissa

	private static long state = 0;

	static void seed(long value)
	{
		state = value;
	}

	static void seedFromTime()
	{
		state = MonoTime.currTime().ticks();
	}

	static double rand()
	{
		// Get next random long value
		long bits = next();

		// Mask lower 52 bits (highest entropy) as mantissa of double in [1.0, 2.0)
		// by bitcasting with exponent bits set to 1023
		bits = DOUBLE_EXPONENT_BITS | (bits & MANTISSA_MASK);
		double result = *(cast(double*)&bits);

		// Subtract 1.0 to get [0.0, 1.0)
		return result - 1.0;
	}

	static long randLong()
	{
		return next();
	}

	static int randInt(int min, int max)
	{
		long range = max - min;
		return min + cast(int)(next() % range);
	}

	static double fastRand()
	{
		// Fast PRNG: grabs current time for entropy, uses XOR-rotate (no multiply)
		long time = MonoTime.currTime().ticks();
		state += time;

		// Fast XOR-add mixing with varied, unrelated shifts
		long x = state;
		x = x ^ (x >> 17);
		x = x + (x << 31);
		x = x ^ (x >> 8);
		x = x + (x << 13);
		x = x ^ (x >> 19);
		x = x + (x << 5);
		x = x ^ (x >> 27);

		// Convert to double in [0.0, 1.0)
		x = DOUBLE_EXPONENT_BITS | (x & MANTISSA_MASK);
		double result = *(cast(double*)&x);
		return result - 1.0;
	}

	static long fastRandLong()
	{
		// Fast PRNG without full mixing
		long time = MonoTime.currTime().ticks();
		state += time;

		long x = state;
		x = x ^ (x >> 17);
		x = x + (x << 31);
		x = x ^ (x >> 8);
		x = x + (x << 13);
		x = x ^ (x >> 19);
		x = x + (x << 5);
		x = x ^ (x >> 27);

		return x;
	}

	private static long next()
	{
		// SplitMix64 variant for better entropy
		state += GOLDEN_RATIO;
		long x = state;
		x = (x ^ (x >> 30)) * MULT_A;
		x = x ^ (x >> 27);
		return x;
	}
}

// Unit test: Distribution check
void testRandomDistribution()
{
	int[100] counts = 0;
	
	Random.seedFromTime();
	
	writeln("Testing distribution of 10000 random numbers...");
	for (int i = 0; i < 10000; i++)
	{
		long val = Random.randLong();
		int index = cast(int)(val % 100);
		counts[index]++;
	}
	
	writeln("\nDistribution (index: count):");
	for (int i = 0; i < 100; i++)
	{
		writeln("Index ", i, ": ", counts[i]);
	}
	
	// Calculate statistics
	int minCount = int.max;
	int maxCount = 0;
	int totalCount = 0;
	
	foreach (count; counts)
	{
		if (count < minCount) minCount = count;
		if (count > maxCount) maxCount = count;
		totalCount += count;
	}
	
	writeln("\nStatistics:");
	writeln("Total: ", totalCount);
	writeln("Expected per bucket: ", totalCount / 100);
	writeln("Min count: ", minCount);
	writeln("Max count: ", maxCount);
	writeln("Range: ", maxCount - minCount);
}