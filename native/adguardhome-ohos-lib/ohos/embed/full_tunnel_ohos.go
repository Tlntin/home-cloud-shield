//go:build ohos_c_shared

package main

import "C"

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	tunnelMaxRules = 256
	tunnelLogLimit = 256 * 1024
)

var tunnel *appTunnel

type appTunnel struct {
	ctx       context.Context
	cancel    context.CancelFunc
	listener  *net.TCPListener
	done      chan struct{}
	clients   sync.WaitGroup
	password  string
	dns       netip.AddrPort
	blockIPv6 bool
	rules     map[netip.AddrPort]struct{}
	log       *os.File
	logSize   int64
	logMu     sync.Mutex
}

func parseTunnelRules(text string) (map[netip.AddrPort]struct{}, error) {
	rules := make(map[netip.AddrPort]struct{})
	for i, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var dst netip.AddrPort
		if ip, err := netip.ParseAddr(line); err == nil && ip.Zone() == "" {
			dst = netip.AddrPortFrom(ip.Unmap(), 0)
		} else if ap, err := netip.ParseAddrPort(line); err == nil && ap.Port() != 0 && ap.Addr().Zone() == "" {
			dst = netip.AddrPortFrom(ap.Addr().Unmap(), ap.Port())
		} else {
			return nil, fmt.Errorf("invalid IP or port on line %d", i+1)
		}
		rules[dst] = struct{}{}
		if len(rules) > tunnelMaxRules {
			return nil, fmt.Errorf("at most %d IP rules are supported", tunnelMaxRules)
		}
	}
	return rules, nil
}

//export ShieldTunnelValidateRules
func ShieldTunnelValidateRules(rules *C.char) *C.char {
	if _, err := parseTunnelRules(C.GoString(rules)); err != nil {
		return C.CString(err.Error())
	}
	return nil
}

// ShieldTunnelStart returns the listener port and password, separated by a
// newline. A failed start returns an error message with no newline.
//
//export ShieldTunnelStart
func ShieldTunnelStart(rules, logPath *C.char, dnsPort, blockIPv6 C.int) *C.char {
	if tunnel != nil {
		return C.CString("tunnel relay already running")
	}
	policy, err := parseTunnelRules(C.GoString(rules))
	if err != nil {
		return C.CString(err.Error())
	}
	var secret [24]byte
	if _, err = rand.Read(secret[:]); err != nil {
		return C.CString("could not generate tunnel credentials")
	}
	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		return C.CString(err.Error())
	}
	logFile, err := os.OpenFile(C.GoString(logPath), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		listener.Close()
		return C.CString(err.Error())
	}
	logInfo, err := logFile.Stat()
	if err != nil {
		logFile.Close()
		listener.Close()
		return C.CString(err.Error())
	}
	ctx, cancel := context.WithCancel(context.Background())
	tunnel = &appTunnel{
		ctx: ctx, cancel: cancel, listener: listener, done: make(chan struct{}),
		password: hex.EncodeToString(secret[:]), rules: policy, log: logFile, logSize: logInfo.Size(),
		dns:       netip.AddrPortFrom(netip.AddrFrom4([4]byte{127, 0, 0, 1}), uint16(dnsPort)),
		blockIPv6: blockIPv6 != 0,
	}
	go tunnel.serve()
	return C.CString(fmt.Sprintf("%d\n%s", listener.Addr().(*net.TCPAddr).Port, tunnel.password))
}

//export ShieldTunnelStop
func ShieldTunnelStop() {
	if tunnel == nil {
		return
	}
	tunnel.cancel()
	tunnel.listener.Close()
	<-tunnel.done
	tunnel.clients.Wait()
	tunnel.log.Close()
	tunnel = nil
}

func (t *appTunnel) record(network, action string, dst netip.AddrPort) {
	line := fmt.Sprintf("%s\t%s\t%s\t%s\n", time.Now().UTC().Format("2006-01-02T15:04:05.000Z"), network, action, dst)
	t.logMu.Lock()
	defer t.logMu.Unlock()
	if t.logSize >= tunnelLogLimit && t.log.Truncate(0) == nil {
		t.logSize = 0
	}
	n, _ := t.log.WriteString(line)
	t.logSize += int64(n)
}

func (t *appTunnel) dial(ctx context.Context, network string, dst netip.AddrPort) (net.Conn, error) {
	ip := dst.Addr()
	_, blockIP := t.rules[netip.AddrPortFrom(ip, 0)]
	_, blockEndpoint := t.rules[dst]
	if blockIP || blockEndpoint || (t.blockIPv6 && ip.Is6()) {
		t.record(network, "blocked", dst)
		return nil, os.ErrPermission
	}
	remote, action := dst, "allowed"
	if dst.Port() == 53 {
		remote, action = t.dns, "dns"
	} else if ip.IsLoopback() || ip.IsUnspecified() || ip.IsMulticast() {
		t.record(network, "blocked", dst)
		return nil, os.ErrPermission
	}
	dialer := net.Dialer{Timeout: 5 * time.Second}
	conn, err := dialer.DialContext(ctx, network, remote.String())
	if err != nil {
		action = "failed"
	}
	if action != "dns" {
		t.record(network, action, dst)
	}
	return conn, err
}

func (t *appTunnel) serve() {
	defer close(t.done)
	slots := make(chan struct{}, 512)
	for {
		client, err := t.listener.AcceptTCP()
		if err != nil {
			return
		}
		select {
		case slots <- struct{}{}:
		default:
			client.Close()
			continue
		}
		t.clients.Add(1)
		go func() {
			defer t.clients.Done()
			defer func() { <-slots }()
			defer client.Close()
			stop := context.AfterFunc(t.ctx, func() { client.Close() })
			defer stop()
			t.handle(client)
		}()
	}
}

// The local relay accepts only authenticated SOCKS5 IP requests from the TUN.
// All reads are exact so a request followed by payload stays on the socket.
func (t *appTunnel) handle(client *net.TCPConn) {
	client.SetDeadline(time.Now().Add(5 * time.Second))
	var header [4]byte
	if _, err := io.ReadFull(client, header[:2]); err != nil || header[0] != 5 {
		return
	}
	methods := make([]byte, int(header[1]))
	if _, err := io.ReadFull(client, methods); err != nil || !strings.ContainsRune(string(methods), 2) {
		client.Write([]byte{5, 255})
		return
	}
	if _, err := client.Write([]byte{5, 2}); err != nil {
		return
	}
	if _, err := io.ReadFull(client, header[:2]); err != nil || header[0] != 1 {
		return
	}
	user := make([]byte, int(header[1])+1)
	if _, err := io.ReadFull(client, user); err != nil {
		return
	}
	pass := make([]byte, int(user[len(user)-1]))
	if _, err := io.ReadFull(client, pass); err != nil {
		return
	}
	if string(user[:len(user)-1]) != "shield" || subtle.ConstantTimeCompare(pass, []byte(t.password)) != 1 {
		client.Write([]byte{1, 1})
		return
	}
	if _, err := client.Write([]byte{1, 0}); err != nil {
		return
	}
	if _, err := io.ReadFull(client, header[:]); err != nil || header[0] != 5 || header[2] != 0 {
		return
	}
	addrLen := tunnelAddressLength(header[3])
	if addrLen == 0 {
		tunnelReply(client, 8, 0)
		return
	}
	var address [18]byte
	if _, err := io.ReadFull(client, address[:addrLen]); err != nil {
		return
	}
	client.SetDeadline(time.Time{})
	switch header[1] {
	case 1:
		dst := tunnelEndpoint(address[:addrLen])
		if dst.Port() != 0 {
			t.handleTCP(client, dst)
		}
	case 3:
		t.handleUDP(client, tunnelEndpoint(address[:addrLen]).Port())
	default:
		tunnelReply(client, 7, 0)
	}
}

func tunnelAddressLength(typ byte) int {
	switch typ {
	case 1:
		return 6
	case 4:
		return 18
	}
	return 0
}

func tunnelEndpoint(address []byte) netip.AddrPort {
	ip, _ := netip.AddrFromSlice(address[:len(address)-2])
	return netip.AddrPortFrom(ip.Unmap(), binary.BigEndian.Uint16(address[len(address)-2:]))
}

func tunnelReply(conn net.Conn, status byte, port uint16) error {
	_, err := conn.Write([]byte{5, status, 0, 1, 127, 0, 0, 1, byte(port >> 8), byte(port)})
	return err
}

func (t *appTunnel) handleTCP(client *net.TCPConn, dst netip.AddrPort) {
	upstream, err := t.dial(t.ctx, "tcp", dst)
	if err != nil {
		tunnelReply(client, 5, 0)
		return
	}
	remote := upstream.(*net.TCPConn)
	defer remote.Close()
	stop := context.AfterFunc(t.ctx, func() { remote.Close() })
	defer stop()
	if tunnelReply(client, 0, 0) != nil {
		return
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		if _, err := io.Copy(remote, client); err != nil {
			remote.Close()
		} else {
			remote.CloseWrite()
		}
	}()
	if _, err := io.Copy(client, remote); err != nil {
		client.Close()
	} else {
		client.CloseWrite()
	}
	<-done
}

func (t *appTunnel) handleUDP(client *net.TCPConn, sourcePort uint16) {
	peer := client.RemoteAddr().(*net.TCPAddr).AddrPort().Addr().Unmap()
	relay, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		tunnelReply(client, 1, 0)
		return
	}
	defer relay.Close()
	if tunnelReply(client, 0, relay.LocalAddr().(*net.UDPAddr).AddrPort().Port()) != nil {
		return
	}
	ctx, cancel := context.WithCancel(t.ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		t.relayDatagrams(ctx, relay, peer, sourcePort)
	}()
	io.Copy(io.Discard, client)
	cancel()
	relay.Close()
	<-done
}

func (t *appTunnel) relayDatagrams(ctx context.Context, relay *net.UDPConn, peer netip.Addr, sourcePort uint16) {
	ctx, cancel := context.WithCancel(ctx)
	var mu sync.Mutex
	var workers sync.WaitGroup
	flows := make(map[netip.AddrPort]net.Conn)
	// A rejected endpoint is cached during the association so retransmissions
	// do not turn a single rejected flow into thousands of entries.
	defer workers.Wait()
	defer cancel()
	buf := make([]byte, 65535)
	for {
		n, src, err := relay.ReadFromUDPAddrPort(buf)
		if err != nil {
			return
		}
		if src.Addr().Unmap() != peer || (sourcePort != 0 && src.Port() != sourcePort) ||
			n < 4 || buf[0] != 0 || buf[1] != 0 || buf[2] != 0 {
			continue
		}
		length := tunnelAddressLength(buf[3])
		if length == 0 || n < 4+length {
			continue
		}
		sourcePort = src.Port()
		dst := tunnelEndpoint(buf[4 : 4+length])
		if dst.Port() == 0 {
			continue
		}
		mu.Lock()
		conn, exists := flows[dst]
		if !exists && len(flows) < 32 {
			conn, _ = t.dial(ctx, "udp", dst)
			flows[dst] = conn
			if conn != nil {
				header := append([]byte(nil), buf[:4+length]...)
				workers.Add(1)
				go func() {
					defer workers.Done()
					stop := context.AfterFunc(ctx, func() { conn.Close() })
					defer stop()
					defer conn.Close()
					defer func() {
						mu.Lock()
						delete(flows, dst)
						mu.Unlock()
					}()
					reply := make([]byte, 65535)
					copy(reply, header)
					for {
						conn.SetReadDeadline(time.Now().Add(time.Minute))
						size, err := conn.Read(reply[len(header):])
						if err != nil {
							return
						}
						if _, err := relay.WriteToUDPAddrPort(reply[:len(header)+size], src); err != nil {
							return
						}
					}
				}()
			}
		}
		mu.Unlock()
		if conn != nil {
			conn.Write(buf[4+length : n])
		}
	}
}
