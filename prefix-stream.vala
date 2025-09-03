#! /usr/bin/env -S vala -X -w -X -I. --vapidir=. --pkg gio-2.0

class PrefixInputStream : FilterInputStream {
    // Bytes that will be returned first from `read()`.
    public ByteArray prefix { get; protected set; }

    public PrefixInputStream(owned InputStream base_stream) {
        Object(base_stream: base_stream, close_base_stream: true);
        this.prefix = new ByteArray();
    }

    // Prepend the specified bytes to this stream.
    public void unread(uint8[] buffer) {
        this.prefix.prepend(buffer);
    }

    public override bool close(Cancellable? cancellable = null) throws IOError {
        if (this.close_base_stream) {
            return this.base_stream.close();
        }
        return true;
    }

    public override ssize_t read(uint8[] buffer, Cancellable? cancellable = null) throws IOError {
        if (this.prefix.len > 0) {
            // Satisfy the read from `this.prefix`.
            var ret = uint.min(this.prefix.len, buffer.length);
            Memory.move(buffer, this.prefix.data, ret);
            this.prefix.remove_range(0, ret);
            return ret;
        } else {
            // Satisfy the read from `this.base_stream`.
            return this.base_stream.read(buffer, cancellable);
        }
    }
}

void debug(string name, uint8[] data) {
	stdout.write(name.data);
	stdout.write(" holds '".data);
	stdout.write(data);
	stdout.write("'\n".data);
}

public static void main(string[] args) {
    InputStream input = new MemoryInputStream.from_data(
        "a single man in possession of a good fortune must be in want of a wife.".data
    );
    PrefixInputStream prefix_input = new PrefixInputStream((owned) input);
    debug("prefix_input.prefix", prefix_input.prefix.data);
    prefix_input.unread(
        "It is a truth universally acknowledged, that ".data
    );
    debug("prefix_input.prefix", prefix_input.prefix.data);
    var output = new uint8[80];
    size_t num_bytes;
    prefix_input.read_all(output, out num_bytes);
    debug("prefix_input.prefix", prefix_input.prefix.data);
    debug("output", output);
}
