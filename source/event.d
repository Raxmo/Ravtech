import core.thread;
import core.time;
import core.sync.mutex;
import core.sync.condition;
import std.stdio;
import std.algorithm;
import utils;

alias Thread = core.thread.Thread;

/**
 * ITrigger - Type-erased trigger interface
 * 
 * All triggers implement this interface to allow type-agnostic scheduling.
 * The scheduler works entirely with ITrigger references.
 */
interface ITrigger
{
	/// Execute the trigger, notifying its linked event with stored payload
	void notify();
}

/**
 * Listener - Wrapper for a delegate and its index
 * 
 * Holds the actual listener delegate and its current position in the event's array.
 * Allocated anywhere (stack, heap, doesn't matter).
 * Event holds pointers to these wrappers.
 */
struct Listener(T)
{
	void delegate(Event!T) listener;  // The actual listener delegate
	size_t index;                      // Current position in event's listener array
}

/**
 * Event - Simple stateful event with typed payload and flat listener pool
 * 
 * Events are notification delivery: fire() calls all listeners.
 * Propagation (hierarchical, conditional, etc.) is caller responsibility.
 * The event object itself is the identity; no string name needed.
 * 
 * Listener removal is O(1) via swap-and-pop with handle-based indexing.
 * 
 * T: Payload type
 */
class Event(T)
{
	alias ListenerPtr = Listener!T*;
	
	protected ListenerPtr[] listeners;  // Array of pointers to listener wrappers
	protected T _payload;
	
	this()
	{
		listeners = [];
	}
	
	/**
	 * Add a listener callback
	 * Returns a pointer to the listener wrapper for O(1) removal
	 * O(1) amortized
	 */
	ListenerPtr addListener(void delegate(Event!T) listener)
	{
		auto listenerObj = new Listener!T();
		listenerObj.listener = listener;
		listenerObj.index = listeners.length;
		listeners ~= listenerObj;
		return listenerObj;
	}
	
	/**
	 * Remove a listener callback via pointer
	 * O(1) swap-and-pop: swap with last, update displaced listener's index, pop
	 */
	void removeListener(ListenerPtr listenerPtr)
	{
		if (listenerPtr is null)
			return;
		
		size_t idx = listenerPtr.index;
		if (idx >= listeners.length)
			return;
		
		// Swap with last element
		if (idx < listeners.length - 1)
		{
			// Move last to current position
			auto lastListener = listeners[$ - 1];
			listeners[idx] = lastListener;
			lastListener.index = idx;
		}
		
		// Pop the last element
		listeners.length--;
	}

	/**
	 * Fire this event, invoking all listeners
	 */
	void fire()
	{
		foreach (listenerPtr; listeners)
		{
			listenerPtr.listener(this);
		}
	}
	
	/**
	 * Notify listeners with a specific payload
	 * Called by triggers to deliver the payload
	 */
	void notifyWithPayload(T payload)
	{
		this._payload = payload;
		fire();
	}
	
	/**
	 * Get payload (called by listeners)
	 */
	@property T payload() const
	{
		return _payload;
	}
}

/**
 * Trigger - Typed trigger implementing ITrigger
 * 
 * Carries an event and payload, implements type-erased notify() interface.
 * Can be executed immediately or scheduled with an IScheduler instance.
 * T: Payload type passed to listeners
 */
class Trigger(T) : ITrigger
{
	Event!T _targetEvent;
	T payload;
	
	this(Event!T event, T data)
	{
		this._targetEvent = event;
		this.payload = data;
	}
	
	/**
	 * Notify the linked event with this trigger's payload
	 * Implements ITrigger interface for type-agnostic scheduling
	 */
	void notify()
	{
		_targetEvent.notifyWithPayload(payload);
	}
	
	@property Event!T event() { return _targetEvent; }
}

/**
 * ScheduledTrigger - Instance of a trigger scheduled for execution
 * 
 * Non-templated node storing ITrigger reference.
 * Intrusive node in circular doubly-linked list.
 * Works with all trigger types regardless of payload.
 */
struct ScheduledTrigger
{
	ITrigger trigger;
	long executeTimeUs;
	ScheduledTrigger* prev;
	ScheduledTrigger* next;
}

debug(EventJitter)
{
	/// Jitter metrics collected during trigger execution (debug builds only)
	struct JitterMetrics
	{
		long[] deltas;           // Individual delta measurements (µs)
		long minDelta = long.max;
		long maxDelta = long.min;
		long sumDelta = 0;
		ulong triggersProcessed = 0;
		
		/// Get average delta in microseconds
		long avgDelta() const
		{
			return triggersProcessed > 0 ? sumDelta / triggersProcessed : 0;
		}
		
		/// Reset metrics
		void reset()
		{
			deltas = [];
			minDelta = long.max;
			maxDelta = long.min;
			sumDelta = 0;
			triggersProcessed = 0;
		}
	}
	__gshared JitterMetrics jitterMetrics;
}

/**
 * Scheduler - Event trigger scheduler with dual execution modes
 * 
 * Two independent execution paths:
 * 1. Synchronous polling (poll):
 *    - Caller invokes poll() each frame
 *    - Executes only ready triggers (no sleeping)
 *    - Frame-aligned, zero async overhead
 * 
 * 2. Asynchronous background thread (exec):
 *    - Caller invokes exec() to start background thread
 *    - Thread sleeps until trigger time, executes
 *    - Fire-and-forget, main thread continues
 *    - scheduleTrigger() just enqueues (non-blocking)
 * 
 * 
 * QUEUE: Circular doubly-linked list sorted by executeTimeUs (O(1) ops)
 * JITTER: Debug mode collects delta measurements (zero production overhead)
 */
class Scheduler
{
	protected ScheduledTrigger* head;
	private Thread schedulerThread;
	private bool running = true;
	private Mutex queueMutex;
	private Condition triggerReady;
	
	this()
	{
		queueMutex = new Mutex();
		triggerReady = new Condition(queueMutex);
	}
	
	/// Insert a node into sorted position (ascending by executeTimeUs)
	private void insertNodeSorted(ScheduledTrigger* node)
	{
		if (head == null)
		{
			// First node
			head = node;
			node.prev = node;
			node.next = node;
			return;
		}
		
		// Walk backwards from tail until we find insertion point
		ScheduledTrigger* position = head.prev;  // Start at tail
		do {
			if (position.executeTimeUs <= node.executeTimeUs)
			{
				// Insert after this position
				node.next = position.next;
				node.prev = position;
				position.next.prev = node;
				position.next = node;
				return;
			}
			position = position.prev;  // Step backwards
		} while (position != head.prev);  // Stop when we loop back to tail
		
		// If we get here, node belongs at head
		node.next = head;
		node.prev = head.prev;
		head.prev.next = node;
		head.prev = node;
		head = node;
	}
	
	/// Schedule trigger for execution (enqueue only)
	ScheduledTrigger* scheduleTrigger(ITrigger trigger, long executeTimeUs)
	{
		ScheduledTrigger* scheduled = new ScheduledTrigger();
		scheduled.trigger = trigger;
		scheduled.executeTimeUs = executeTimeUs;
		scheduled.prev = null;
		scheduled.next = null;
		
		synchronized (queueMutex)
		{
			ScheduledTrigger* oldHead = head;
			insertNodeSorted(scheduled);
			
			// If this node became the new head, wake background thread
			if (head == scheduled && oldHead != scheduled)
			{
				triggerReady.notify();
			}
		}
		
		return scheduled;
	}
	
	/// Schedule trigger with relative delay from now
	ScheduledTrigger* delayTrigger(ITrigger trigger, long delayUs)
	{
		long executeTimeUs = TimeUtils.currTimeUs() + delayUs;
		return scheduleTrigger(trigger, executeTimeUs);
	}
	
	
	/// Remove a scheduled trigger from the timeline (must be called with queueMutex held)
	private void removeScheduledTriggerUnsafe(ScheduledTrigger* node)
	{
		if (node == null || head == null)
			return;
		
		// Check if this is the only node remaining
		if (node.next == node)
		{
			// Only node in list - clear the pool
			head = null;
		}
		else
		{
			// Normal removal: unlink the node from the cycle
			node.prev.next = node.next;
			node.next.prev = node.prev;
			
			// Update head if we removed it
			if (head == node)
			{
				head = node.next;
			}
		}
		
		destroy(node);
	}
	
	/// Remove a scheduled trigger from the timeline (thread-safe)
	void removeScheduledTrigger(ScheduledTrigger* node)
	{
		synchronized (queueMutex)
		{
			removeScheduledTriggerUnsafe(node);
		}
	}
	
	/// Clear all pending triggers and reset state
	void clear()
	{
		synchronized (queueMutex)
		{
			while (head != null)
			{
				removeScheduledTriggerUnsafe(head);
			}
		}
	}
	
	/// Background thread loop - sleeps until trigger time, executes when ready
	private void backgroundLoop()
	{
		while (running)
		{
			ScheduledTrigger* currentNode;
			long delayUs;
			
			// Lock to check queue and read execution time
			synchronized (queueMutex)
			{
				if (head == null)
					break;
				
				currentNode = head;
				long nowUs = TimeUtils.currTimeUs();
				delayUs = head.executeTimeUs - nowUs;
				
				// If trigger is ready now, don't wait
				if (delayUs <= 0)
				{
					// Time arrived, execute trigger immediately (still holding lock)
					debug(EventJitter)
					{
						long deltaUs = TimeUtils.currTimeUs() - currentNode.executeTimeUs;
						jitterMetrics.deltas ~= deltaUs;
						jitterMetrics.minDelta = min(jitterMetrics.minDelta, deltaUs);
						jitterMetrics.maxDelta = max(jitterMetrics.maxDelta, deltaUs);
						jitterMetrics.sumDelta += deltaUs;
						jitterMetrics.triggersProcessed++;
					}
					
					ITrigger triggerToExecute = currentNode.trigger;
					removeScheduledTriggerUnsafe(currentNode);
					
					// Release lock and execute (avoid deadlock if notify() schedules)
					queueMutex.unlock();
					triggerToExecute.notify();
					queueMutex.lock();
					continue;
				}
				
				// Not ready yet - will wait on condition variable below
			}
			
			// Trigger not ready, wait on condition with timeout
			// Cap at 1 second to ensure responsiveness to stop() signal
			long waitMs = min(1000, (delayUs + 500) / 1000);
			synchronized (queueMutex)
			{
				// Re-check queue state before waiting (might have changed)
				if (head == null)
					break;
				
				try {
					triggerReady.wait(dur!"msecs"(waitMs));
				} catch (Exception e) {
					// Timeout is normal, not an error - just continue loop
				}
			}
		}
	}
	
	/// Poll for ready triggers synchronously (frame-aligned polling mode)
	/// Call this once per frame in your game loop
	void poll()
	{
		long currentTimeUs = TimeUtils.currTimeUs();
		
		while (true)
		{
			ScheduledTrigger* currentNode;
			
			// Lock to check if next trigger is ready
			synchronized (queueMutex)
			{
				if (head == null || head.executeTimeUs > currentTimeUs)
					break;
				
				currentNode = head;
			}
			
			// Execute trigger outside lock (avoid deadlock)
			currentNode.trigger.notify();
			
			// Remove from queue with lock held
			synchronized (queueMutex)
			{
				removeScheduledTriggerUnsafe(currentNode);
			}
		}
	}
	
	/// Execute pending triggers asynchronously (background thread mode)
	void exec()
	{
		// Spawn/maintain background thread if not already running
		if (schedulerThread is null || !schedulerThread.isRunning)
		{
			schedulerThread = new Thread(&backgroundLoop);
			schedulerThread.isDaemon = true;
			schedulerThread.start();
		}
	}
	
	/// Stop the background thread cleanly (must be called after exec() before test cleanup)
	void stop()
	{
		synchronized (queueMutex)
		{
			running = false;
			triggerReady.notifyAll();  // Wake thread in case it's sleeping
		}
		
		// Wait for thread to complete
		if (schedulerThread !is null && schedulerThread.isRunning)
		{
			schedulerThread.join();
		}
	}
}
