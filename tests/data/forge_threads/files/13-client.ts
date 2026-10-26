    }

    private scheduleImmediateBatch(): void {
        if (this.nextBatch) return;
        this.nextBatch = setImmediate(this.doBatch.bind(this));
    }

    batchContext(): { [Symbol.dispose](): void; } {
        if (this.nextBatch === "manual") {
            throw new Error("Already in a manual batch context");
        }
        if (this.nextBatch) {
            clearImmediate(this.nextBatch);
            this.doBatch(); // empty the queue before entering a manual batch context
        }
        this.nextBatch = "manual";
        return {
            [Symbol.dispose]: () => {
                this.nextBatch = undefined;
                this.scheduleImmediateBatch();
            },
        };
    }

    async apiRequest<K extends APIRequest["method"]>(method: K, params: APIMethodInfo[K]["params"]): Promise<APIMethodInfo[K]["result"]> {
        if (this.closed) throw new Error("Client is closed");
        if (!this.connected) {
            await this.connect();
        }
        if (!this.connection) {
            throw new Error("Connection not established");
        }

        const resultPromise = new Promise<APIMethodInfo[K]["result"]>((resolve, reject) => {
            this.batchedRequests.push({ method, params, resolve, reject });
            this.scheduleImmediateBatch();
        });
        return resultPromise;
    }

    async apiRequestBinary<K extends SourceFileResponseMethod>(method: K, params: APIMethodInfo[K]["params"]): Promise<Uint8Array | undefined> {
        const response = await this.apiRequest(method, params);
        if (!response) return undefined;
        const buffer = Buffer.from(response.data, "base64");
        return new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength);
    }

    /**
     * Returns the timing collector that per-node materialization is reported
     * into, or undefined when timing collection is disabled. The returned
     * collector is the same one folded into {@link getTimingInfo}, so
     * materialization totals surface alongside request timings.
     */
    getTimingCollector(): TimingCollector | undefined {
        return this.timing;
    }

    /**
     * Returns a combined timing snapshot: client-measured round-trip and byte
     * counts folded together with the server's own per-request processing time
     * (fetched via a getServerTiming request) and estimated transport overhead.
     */
    async getTimingInfo(): Promise<TimingInfo> {
        if (!this.timing) {
            return disabledTimingInfo();
        }
        const local = this.timing.getInfo();
        // No requests have been sent yet: nothing to fetch from the server.
        if (!this.connected || !this.connection) {
            return local;
        }
        return combineTimingInfo(local, await this.fetchServerTiming());
    }

    async resetTimingInfo(): Promise<void> {
        if (!this.timing) return;
        this.timing.reset();
        if (this.connected && this.connection) {
            // Keep the server's collection in sync so combined totals stay meaningful.
            const requestType = new RequestType<unknown, void, void>("resetServerTiming");
            await this.connection.sendRequest(requestType, undefined);
        }
    }

    private async fetchServerTiming(): Promise<ServerTimingInfo> {
        if (!this.connection) {
            return disabledServerTimingInfo();
        }
        // Fetch the server's own timing collection via a dedicated request. This
        // bypasses the client-side collector so the query does not pollute it.
        const requestType = new RequestType<unknown, ServerTimingInfo, void>("getServerTiming");
        return this.connection.sendRequest(requestType, undefined);
    }

    close(): Promise<void> {
        return this.closing ??= this.closeWorker();
    }

    private async closeWorker(): Promise<void> {
        await this.connecting?.catch(() => {}); // if connection is still in-progress, wait for it to finish before closing the connection
        this.closed = true;
        try {
            if (this.timingDump && this.timing) {
                const local = this.timing.getInfo();
                let server: ServerTimingInfo | undefined;
                let serverTimingError: string | undefined;
                const connection = this.connection;
                // Closing alone does not reject pending JSON-RPC requests.
                const onClose = connection?.onClose(() => connection.dispose());
                try {
                    if (this.connected) server = await this.fetchServerTiming();
                }
                catch (error) {
                    serverTimingError = String(error);
                }
                finally {
                    onClose?.dispose();
                }
                this.timingDump.write(local, server, serverTimingError);
            }
        }
        finally {
            if (this.connection) {
                this.connection.dispose();
                this.connection = undefined;
            }
            if (this.socket) {
                this.socket.destroy();
                this.socket = undefined;
            }
            if (this.process) {
                // Close stdin to unblock the server's read loop, allowing it to exit cleanly.
                // The server is blocked on stdin.Read(), so just sending SIGTERM would deadlock:
                // - Node won't exit while child is alive
                // - Child can't process SIGTERM while blocked on read
                // - Read won't error until stdin is closed
                this.process.stdin?.end();
                this.process = undefined;
            }
            this.connected = false;
        }
    }
}
