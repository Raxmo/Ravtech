import core.thread;
import std.stdio;
import std.math;
import event;
import utils;

/**
 * Event Chaining Focused Benchmark
 * Measures event chaining performance under controlled conditions.
 * Tests the ring buffer architecture's ability to handle chains correctly.
 */

void benchmarkChainCorrectness()
{
	writeln("\n=== Event Chaining Correctness Benchmark ===\n");
	
	// Test 1: Linear chain (A → B → C → ... → Z)
	{
		writeln("Test 1: Linear chain (A → B → C ... = 5 events)");
		
		EventScheduler scheduler = new EventScheduler();
		int executionCount = 0;
		
		long baseTimeUs = TimeUtils.currTimeUs();
		long startTimeUs = baseTimeUs;
		
		// Start the chain: each event immediately schedules the next
		scheduler.scheduleAtTime(baseTimeUs, () {
			executionCount++;  // A
			scheduler.scheduleAtTime(TimeUtils.currTimeUs(), () {
				executionCount++;  // B
				scheduler.scheduleAtTime(TimeUtils.currTimeUs(), () {
					executionCount++;  // C
					scheduler.scheduleAtTime(TimeUtils.currTimeUs(), () {
						executionCount++;  // D
						scheduler.scheduleAtTime(TimeUtils.currTimeUs(), () {
							executionCount++;  // E
						});
					});
				});
			});
		});
		
		// Process events
		long deadline = baseTimeUs + 100_000;
		while (scheduler.hasEvents() && TimeUtils.currTimeUs() < deadline)
		{
			scheduler.processEvents();
		}
		
		long totalTimeUs = TimeUtils.currTimeUs() - startTimeUs;
		writeln("  Events executed: ", executionCount);
		writeln("  Total time: ", totalTimeUs, " µs");
		writeln("  Expected 5: ", (executionCount == 5));
	}
	
	// Test 2: Multiple simultaneous events scheduling children
	{
		writeln("\nTest 2: Fan-out scheduling (3 events each spawn 3 children)");
		
		EventScheduler scheduler = new EventScheduler();
		int executionCount = 0;
		
		long baseTimeUs = TimeUtils.currTimeUs();
		long startTimeUs = baseTimeUs;
		
		// Schedule 3 initial events
		for (int i = 0; i < 3; i++)
		{
			scheduler.scheduleAtTime(baseTimeUs, () {
				executionCount++;  // Parent
				
				// Each parent schedules 3 children
				for (int j = 0; j < 3; j++)
				{
					scheduler.scheduleAtTime(TimeUtils.currTimeUs(), () {
						executionCount++;  // Child
					});
				}
			});
		}
		
		// Process events
		long deadline = baseTimeUs + 1_000_000;
		while (scheduler.hasEvents() && TimeUtils.currTimeUs() < deadline)
		{
			scheduler.processEvents();
		}
		
		long totalTimeUs = TimeUtils.currTimeUs() - startTimeUs;
		int expectedCount = 3 + (3 * 3);  // 3 parents + 9 children
		
		writeln("  Events executed: ", executionCount, " (expected: ", expectedCount, ")");
		writeln("  Total time: ", totalTimeUs, " µs");
		writeln("  Count correct: ", (executionCount == expectedCount));
	}
	
	// Test 3: Chain with cancellation
	{
		writeln("\nTest 3: Chain with mid-execution cancellation");
		
		EventScheduler scheduler = new EventScheduler();
		int[] executionLog;
		
		long baseTimeUs = TimeUtils.currTimeUs();
		long startTimeUs = baseTimeUs;
		
		ref ScheduledEvent eventB = scheduler.scheduleAtTime(baseTimeUs + 1_000, () {
			executionLog ~= 2;  // Should not execute
		});
		
		scheduler.scheduleAtTime(baseTimeUs, () {
			executionLog ~= 1;  // A
			scheduler.cancel(eventB);  // Cancel B during A
			scheduler.scheduleAtTime(TimeUtils.currTimeUs() + 1_000, () {
				executionLog ~= 3;  // C (new event, should execute)
			});
		});
		
		// Process events
		long deadline = baseTimeUs + 100_000;
		while (scheduler.hasEvents() && TimeUtils.currTimeUs() < deadline)
		{
			scheduler.processEvents();
		}
		
		long totalTimeUs = TimeUtils.currTimeUs() - startTimeUs;
		
		writeln("  Execution log: [", executionLog[0], ", ", executionLog[1], "]");
		writeln("  B was canceled: ", (executionLog.length == 2 && executionLog[0] == 1 && executionLog[1] == 3));
		writeln("  Total time: ", totalTimeUs, " µs");
	}
	
	// Test 4: Cascading reschedules
	{
		writeln("\nTest 4: Cascading reschedules (5-level deep)");
		
		EventScheduler scheduler = new EventScheduler();
		int runCount = 0;
		
		long baseTimeUs = TimeUtils.currTimeUs();
		long startTimeUs = baseTimeUs;
		
		void cascadeSchedule(int depth)
		{
			if (depth == 0) return;
			
			runCount++;
			
			// Schedule next level immediately
			scheduler.scheduleAtTime(TimeUtils.currTimeUs(), () {
				cascadeSchedule(depth - 1);
			});
		}
		
		scheduler.scheduleAtTime(baseTimeUs, () {
			cascadeSchedule(5);
		});
		
		// Process events
		long deadline = baseTimeUs + 1_000_000;
		while (scheduler.hasEvents() && TimeUtils.currTimeUs() < deadline)
		{
			scheduler.processEvents();
		}
		
		long totalTimeUs = TimeUtils.currTimeUs() - startTimeUs;
		
		writeln("  Runs: ", runCount);
		writeln("  Total time: ", totalTimeUs, " µs");
		writeln("  All runs executed: ", (runCount == 5));
	}
	
	writeln("\n=== Correctness Benchmark Complete ===\n");
}

void main()
{
	benchmarkChainCorrectness();
}
