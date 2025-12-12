import core.time;
import std.stdio;
import std.conv;
import utils;
import logger;

void main()
{
	Logger logger = new Logger();
	logger.file("prng_benchmark.log");
	
	logger.info("===== SplitMix64 PRNG Benchmark =====");
	
	Random rng = new Random(12345);
	
	// Benchmark: long generation
	logger.info("Benchmarking: 100,000,000 long generations");
	MonoTime startLong = MonoTime.currTime();
	for (long i = 0; i < 100_000_000; i++) {
		rng.opCall!long();
	}
	Duration durationLong = MonoTime.currTime() - startLong;
	double nsPerLong = durationLong.total!"nsecs" / 100_000_000.0;
	logger.info("Time: " ~ durationLong.toString() ~ " ns per call: " ~ to!string(nsPerLong));
	
	// Benchmark: int generation
	logger.info("Benchmarking: 100,000,000 int generations");
	MonoTime startInt = MonoTime.currTime();
	for (long i = 0; i < 100_000_000; i++) {
		rng.opCall!int();
	}
	Duration durationInt = MonoTime.currTime() - startInt;
	double nsPerInt = durationInt.total!"nsecs" / 100_000_000.0;
	logger.info("Time: " ~ durationInt.toString() ~ " ns per call: " ~ to!string(nsPerInt));
	
	// Benchmark: double generation
	logger.info("Benchmarking: 100,000,000 double generations");
	MonoTime startDouble = MonoTime.currTime();
	for (long i = 0; i < 100_000_000; i++) {
		rng.opCall!double();
	}
	Duration durationDouble = MonoTime.currTime() - startDouble;
	double nsPerDouble = durationDouble.total!"nsecs" / 100_000_000.0;
	logger.info("Time: " ~ durationDouble.toString() ~ " ns per call: " ~ to!string(nsPerDouble));
	
	// Benchmark: normal distribution
	logger.info("Benchmarking: 50,000,000 normal distribution calls");
	MonoTime startNormal = MonoTime.currTime();
	for (long i = 0; i < 50_000_000; i++) {
		rng.normal();
	}
	Duration durationNormal = MonoTime.currTime() - startNormal;
	double nsPerNormal = durationNormal.total!"nsecs" / 50_000_000.0;
	logger.info("Time: " ~ durationNormal.toString() ~ " ns per call: " ~ to!string(nsPerNormal));
	
	logger.info("===== Benchmark Complete =====");
}
