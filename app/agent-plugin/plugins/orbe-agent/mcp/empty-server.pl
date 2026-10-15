# ツール 0 個の MCP サーバー（stdio・改行区切りの JSON-RPC）。MCP シムが、自分のチャネルの Orbe の
# タブでないときに exec する。Orbe の外には orbe-mcp が無いので、macOS 標準の perl で書く。
use strict;
use warnings;
use JSON::PP;

my $json = JSON::PP->new->canonical;
$| = 1;

sub reply {
  my ($id, $key, $value) = @_;
  print $json->encode({ jsonrpc => '2.0', id => $id, $key => $value }), "\n";
}

while (my $line = <STDIN>) {
  my $msg = eval { $json->decode($line) };
  next unless ref $msg eq 'HASH' && exists $msg->{id};
  my $id = $msg->{id};
  my $method = $msg->{method} // '';
  if ($method eq 'initialize') {
    my $params = ref $msg->{params} eq 'HASH' ? $msg->{params} : {};
    reply($id, result => {
      protocolVersion => $params->{protocolVersion} // '2025-06-18',
      capabilities => {},
      serverInfo => { name => 'orbe', version => '0.1.0' },
    });
  } elsif ($method eq 'tools/list') {
    reply($id, result => { tools => [] });
  } elsif ($method eq 'ping') {
    reply($id, result => {});
  } else {
    reply($id, error => { code => -32601, message => "Method not found: $method" });
  }
}
