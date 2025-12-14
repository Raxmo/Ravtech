import core.thread;
import std.stdio;
import std.math;
import event;
import utils;

/**
 * Event Chaining Benchmark
 * Measures throughput and latency of event scheduling and execution.
 * Tests the ring buffer architecture under realistic load.
 */

void benchmarkEventChaining()
{
	import core.time : dur;
	
	writeln("\n=== Event Chaining Benchmark ===\n");
	
	// Benchmark 1: Simple event scheduling throughput
	{
		EventScheduler scheduler = new EventScheduler();
		long startTimeUs = TimeUtils.currTimeUs();
		
		int eventCount = 10_000;
		for (int i = 0; i < eventCount; i++)
		{
			scheduler.scheduleAtTime(startTimeUs + 100_000, () {
				// Dummy work
			});
		}
		
		long scheduleTimeUs = TimeUtils.currTimeUs() - startTimeUs;
		double eventsPerMicro = eventCount / cast(double)scheduleTimeUs;
		
		writeln("Benchmark 1: Schedule throughput");
		writeln("  Scheduled: ", eventCount, " events");
		writeln("  Time: ", scheduleTimeUs, " µs");
		writeln("  Throughput: ", eventsPerMicro, " events/µs (", eventsPerMicro * 1_000_000, " events/sec)");
	}
	
	// Benchmark 2: Event processing latency (depth 1 - single events)
	{
		EventScheduler scheduler = new EventScheduler();
		long[] executionLatencies;
		
		long baseTimeUs = TimeUtils.currTimeUs();
		int eventCount = 1_000;
		
		for (int i = 0; i < eventCount; i++)
		{
			long scheduleTimeUs = baseTimeUs + (i * 1_000);  // 1ms between events
			scheduler.scheduleAtTime(scheduleTimeUs, () {
				long actualTimeUs = TimeUtils.currTimeUs();
				long scheduledTimeUs = baseTimeUs + (cast(int)executionLatencies.length * 1_000);
				long latencyUs = actualTimeUs - scheduledTimeUs;
				executionLatencies ~= latencyUs;
			});
		}
		
		// Process all events
		long pollDeadlineUs = baseTimeUs + (eventCount * 1_000) + 50_000;
		while (scheduler.hasEvents() && TimeUtils.currTimeUs() < pollDeadlineUs)
		{
			scheduler.processEvents();
		}
		
		writeln("\nBenchmark 2: Event processing latency (1ms intervals, ", eventCount, " events)");
		if (executionLatencies.length > 0)
		{
			long minLatency = executionLatencies[0];
			long maxLatency = executionLatencies[0];
			long sumLatency = 0;
			long sumSquaredLatency = 0;
			
			foreach (lat; executionLatencies)
			{
				if (lat < minLatency) minLatency = lat;
				if (lat > maxLatency) maxLatency = lat;
				sumLatency += lat;
				sumSquaredLatency += lat * lat;
			}
			
			long meanLatency = sumLatency / cast(long)executionLatencies.length;
			long varianceLatency = sumSquaredLatency / cast(long)executionLatencies.length - (meanLatency * meanLatency);
			double stddevLatency = (varianceLatency >= 0) ? sqrt(cast(double)varianceLatency) : 0.0;
			
			writeln("  Min latency:  ", minLatency, " µs");
			writeln("  Max latency:  ", maxLatency, " µs");
			writeln("  Mean latency: ", meanLatency, " µs");
			writeln("  Stddev:       ", stddevLatency, " µs");
			writeln("  Events exec:  ", executionLatencies.length);
		}
	}
	
	// Benchmark 3: Event chaining depth (A → B → C → ...)
	{
		writeln("\nBenchmark 3: Event chaining depth (chain length, 100 iterations)");
		
		for (int depth = 1; depth <= 4; depth++)
		{
			EventScheduler scheduler = new EventScheduler();
			long totalStartTimeUs = TimeUtils.currTimeUs();
			long baseTimeUs = totalStartTimeUs;
			
			int iterations = 100;
			long[] chainExecutionTimes;
			
			for (int iter = 0; iter < iterations; iter++)
			{
				long chainStartTimeUs = TimeUtils.currTimeUs();
				
				// Build a chain of 'depth' events
				long scheduleTimeUs = baseTimeUs + iter * 10_000;  // 10ms between chain iterations
				
				// Recursive lambda builder
				void scheduleChain(int d)
				{
					if (d == 0)
					{
						long endTimeUs = TimeUtils.currTimeUs();
						chainExecutionTimes ~= (endTimeUs - chainStartTimeUs);
						return;
					}
					
					scheduler.scheduleAtTime(scheduleTimeUs + (d * 100), () {
						scheduleChain(d - 1);
					});
				}
				
				scheduleChain(depth);
			}
			
			// Process all events
			long pollDeadlineUs = baseTimeUs + (iterations * 10_000) + 100_000;
			while (scheduler.hasEvents() && TimeUtils.currTimeUs() < pollDeadlineUs)
			{
				scheduler.processEvents();
			}
			
			if (chainExecutionTimes.length > 0)
			{
				long minTime = chainExecutionTimes[0];
				long maxTime = chainExecutionTimes[0];
				long sumTime = 0;
				
				foreach (t; chainExecutionTimes)
				{
					if (t < minTime) minTime = t;
					if (t > maxTime) maxTime = t;
					sumTime += t;
				}
				
				long meanTime = sumTime / cast(long)chainExecutionTimes.length;
				
				writeln("  Depth ", depth, ": min=", minTime, "µs, max=", maxTime, "µs, mean=", meanTime, "µs");
			}
		}
	}
	
	// Benchmark 4: Ring buffer overhead (many small events, few large)
	{
		writeln("\nBenchmark 4: Ring buffer behavior (1000 small + 10 large events)");
		
		EventScheduler scheduler = new EventScheduler();
		long baseTimeUs = TimeUtils.currTimeUs();
		
		// Schedule 1000 small events (execute quickly)
		for (int i = 0; i < 1000; i++)
		{
			scheduler.scheduleAtTime(baseTimeUs + 5_000 + (i % 10), () {
				// Minimal work
			});
		}
		
		// Schedule 10 large events (execute after small ones)
		for (int i = 0; i < 10; i++)
		{
			scheduler.scheduleAtTime(baseTimeUs + 100_000 + (i * 1_000), () {
				// Slightly more work
				int dummy = 0;
				for (int j = 0; j < 100; j++) dummy += j;
			});
		}
		
		long processStartTimeUs = TimeUtils.currTimeUs();
		while (scheduler.hasEvents() && TimeUtils.currTimeUs() < baseTimeUs + 200_000)
		{
			scheduler.processEvents();
		}
		long processTimeUs = TimeUtils.currTimeUs() - processStartTimeUs;
		
		writeln("  Total events: 1010");
		writeln("  Process time: ", processTimeUs, " µs");
		writeln("  Per-event avg: ", processTimeUs / 1010.0, " µs");
	}
	
	writeln("\n=== Benchmark Complete ===\n");
}

void main()
{
	benchmarkEventChaining();
}
