use gstreamer as gst;
use gstreamer::prelude::*;

const TS_PACKET_SIZE: usize = 188;

const fn crc32_table() -> [u32; 256] {
    let mut table = [0u32; 256];
    let mut index = 0;
    while index < table.len() {
        let mut value = (index as u32) << 24;
        let mut bit = 0;
        while bit < 8 {
            value = if value & 0x8000_0000 != 0 {
                (value << 1) ^ 0x04c1_1db7
            } else {
                value << 1
            };
            bit += 1;
        }
        table[index] = value;
        index += 1;
    }
    table
}

const CRC32_TABLE: [u32; 256] = crc32_table();

fn mpeg_crc32(data: &[u8]) -> u32 {
    data.iter().fold(0xffff_ffff, |crc, byte| {
        let table_index = ((crc >> 24) as u8 ^ *byte) as usize;
        (crc << 8) ^ CRC32_TABLE[table_index]
    })
}

pub fn rewrite_buffer(data: &mut [u8], program_number: u16) -> bool {
    if data.len() % TS_PACKET_SIZE != 0
        || data
            .chunks_exact(TS_PACKET_SIZE)
            .any(|packet| packet[0] != 0x47)
    {
        return false;
    }

    let mut changed = false;
    for packet in data.chunks_exact_mut(TS_PACKET_SIZE) {
        changed |= rewrite_packet(packet, program_number);
    }
    changed
}

pub fn install_probe(pad: &gst::Pad, program_number: u16) {
    pad.add_probe(gst::PadProbeType::BUFFER, move |_pad, info| {
        if let Some(buffer) = info.buffer_mut() {
            if let Ok(mut map) = buffer.make_mut().map_writable() {
                rewrite_buffer(map.as_mut_slice(), program_number);
            }
        }
        gst::PadProbeReturn::Ok
    });
}

fn rewrite_packet(packet: &mut [u8], program_number: u16) -> bool {
    if packet.len() != TS_PACKET_SIZE || packet[0] != 0x47 {
        return false;
    }

    let transport_error = packet[1] & 0x80 != 0;
    let pid = (u16::from(packet[1] & 0x1f) << 8) | u16::from(packet[2]);
    if transport_error || pid != 0 {
        return false;
    }

    let adaptation_field_control = (packet[3] >> 4) & 0x03;
    if adaptation_field_control == 0 || adaptation_field_control == 2 {
        return false;
    }

    let mut payload_start = 4;
    if adaptation_field_control == 3 {
        let Some(&adaptation_length) = packet.get(payload_start) else {
            return false;
        };
        payload_start += 1 + usize::from(adaptation_length);
        if payload_start > TS_PACKET_SIZE {
            return false;
        }
    }

    if packet[1] & 0x40 == 0 {
        return false;
    }
    let Some(&pointer_field) = packet.get(payload_start) else {
        return false;
    };
    let section_start = payload_start + 1 + usize::from(pointer_field);
    if section_start
        .checked_add(3)
        .is_none_or(|end| end > TS_PACKET_SIZE)
    {
        return false;
    }

    let section_length = ((usize::from(packet[section_start + 1] & 0x0f)) << 8)
        | usize::from(packet[section_start + 2]);
    let section_end = match section_start.checked_add(3 + section_length) {
        Some(end) if end <= TS_PACKET_SIZE => end,
        _ => return false,
    };
    if packet[section_start] != 0x00
        || packet[section_start + 1] & 0x80 == 0
        || packet[section_start + 1] & 0x30 != 0x30
        || !(9..=1021).contains(&section_length)
        || packet[section_start + 7] != 0
        || mpeg_crc32(&packet[section_start..section_end]) != 0
    {
        return false;
    }

    let entries_start = section_start + 8;
    let entries_end = section_end - 4;
    if entries_end < entries_start || (entries_end - entries_start) % 4 != 0 {
        return false;
    }

    let mut kept_entries = [[0u8; 4]; 256];
    let mut kept_count = 0;
    for entry in packet[entries_start..entries_end].chunks_exact(4) {
        if entry[2] & 0xe0 != 0xe0 {
            return false;
        }
        let entry_program = u16::from_be_bytes([entry[0], entry[1]]);
        if entry_program == program_number {
            kept_entries[kept_count].copy_from_slice(entry);
            kept_count += 1;
        }
    }

    let new_section_length = 9 + kept_count * 4;
    let mut rewritten = [0xffu8; TS_PACKET_SIZE];
    rewritten[..section_start].copy_from_slice(&packet[..section_start]);
    rewritten[section_start..section_start + 8]
        .copy_from_slice(&packet[section_start..entries_start]);
    rewritten[section_start + 1] =
        (packet[section_start + 1] & 0xf0) | ((new_section_length >> 8) as u8 & 0x0f);
    rewritten[section_start + 2] = new_section_length as u8;

    let mut output = section_start + 8;
    for entry in kept_entries.iter().take(kept_count) {
        rewritten[output..output + 4].copy_from_slice(entry);
        output += 4;
    }
    let crc = mpeg_crc32(&rewritten[section_start..output]);
    rewritten[output..output + 4].copy_from_slice(&crc.to_be_bytes());
    packet.copy_from_slice(&rewritten);
    true
}

#[cfg(test)]
mod tests {
    use super::{install_probe, mpeg_crc32, rewrite_buffer, TS_PACKET_SIZE};
    use gstreamer as gst;
    use gstreamer::prelude::*;
    use std::sync::{Arc, Mutex};

    fn pat_section(entries: &[u16], last_section_number: u8) -> Vec<u8> {
        let section_length = 9 + entries.len() * 4;
        let mut section = vec![
            0x00,
            0xb0 | (section_length >> 8) as u8,
            section_length as u8,
            0x12,
            0x34,
            0xc1,
            0x00,
            last_section_number,
        ];
        for program_number in entries {
            section.extend_from_slice(&program_number.to_be_bytes());
            section.extend_from_slice(&0xe000u16.to_be_bytes());
        }
        let crc = mpeg_crc32(&section);
        section.extend_from_slice(&crc.to_be_bytes());
        section
    }

    fn packet_with_section(section: &[u8], adaptation_length: Option<u8>) -> [u8; TS_PACKET_SIZE] {
        packet_with_section_and_pointer(section, adaptation_length, 0)
    }

    fn packet_with_section_and_pointer(
        section: &[u8],
        adaptation_length: Option<u8>,
        pointer_field: u8,
    ) -> [u8; TS_PACKET_SIZE] {
        let mut packet = [0xffu8; TS_PACKET_SIZE];
        packet[0] = 0x47;
        packet[1] = 0x40;
        packet[2] = 0x00;
        packet[3] = if adaptation_length.is_some() {
            0x30
        } else {
            0x10
        };
        let payload_start = if let Some(length) = adaptation_length {
            packet[4] = length;
            packet[5..5 + usize::from(length)].fill(0);
            5 + usize::from(length)
        } else {
            4
        };
        packet[payload_start] = pointer_field;
        let section_start = payload_start + 1 + usize::from(pointer_field);
        packet[payload_start + 1..section_start].fill(0);
        packet[section_start..section_start + section.len()].copy_from_slice(section);
        packet
    }

    fn packet_with_pid(pid: u16) -> [u8; TS_PACKET_SIZE] {
        let mut packet = [0xffu8; TS_PACKET_SIZE];
        packet[0] = 0x47;
        packet[1] = 0x10 | ((pid >> 8) as u8 & 0x1f);
        packet[2] = pid as u8;
        packet[3] = 0x10;
        packet
    }

    fn entries(packet: &[u8; TS_PACKET_SIZE]) -> Vec<u16> {
        entries_at(packet, 5)
    }

    fn entries_at(packet: &[u8; TS_PACKET_SIZE], section_start: usize) -> Vec<u16> {
        let section_length = ((usize::from(packet[section_start + 1] & 0x0f)) << 8)
            | usize::from(packet[section_start + 2]);
        packet[section_start + 8..section_start + 3 + section_length - 4]
            .chunks_exact(4)
            .map(|entry| u16::from_be_bytes([entry[0], entry[1]]))
            .collect()
    }

    #[test]
    fn reduces_two_program_pat_and_recomputes_crc() {
        let mut packet = packet_with_section(&pat_section(&[11, 12], 0), None);
        assert!(rewrite_buffer(&mut packet, 12));
        assert_eq!(entries(&packet), [12]);
        let section_length = usize::from(packet[6] & 0x0f) << 8 | usize::from(packet[7]);
        assert_eq!(mpeg_crc32(&packet[5..5 + 3 + section_length]), 0);
    }

    #[test]
    fn leaves_unrelated_pid_untouched() {
        let mut packet = packet_with_pid(100);
        let original = packet;
        assert!(!rewrite_buffer(&mut packet, 12));
        assert_eq!(packet, original);
    }

    #[test]
    fn leaves_pmt_packet_untouched() {
        let mut packet = packet_with_pid(4097);
        packet[4] = 0x02;
        let original = packet;
        assert!(!rewrite_buffer(&mut packet, 12));
        assert_eq!(packet, original);
    }

    #[test]
    fn preserves_adaptation_field_when_rewriting() {
        let mut packet = packet_with_section(&pat_section(&[11, 12], 0), Some(7));
        let adaptation = packet[5..12].to_vec();
        assert!(rewrite_buffer(&mut packet, 11));
        assert_eq!(&packet[5..12], adaptation.as_slice());
        assert_eq!(entries_at(&packet, 13), [11]);
    }

    #[test]
    fn honors_pointer_field_before_pat_section() {
        let mut packet = packet_with_section_and_pointer(&pat_section(&[11, 12], 0), None, 3);
        let prefix = packet[4..8].to_vec();
        assert!(rewrite_buffer(&mut packet, 12));
        assert_eq!(&packet[4..8], prefix.as_slice());
        assert_eq!(entries_at(&packet, 8), [12]);
    }

    #[test]
    fn leaves_truncated_section_untouched() {
        let mut packet = packet_with_section(&pat_section(&[11, 12], 0), None);
        packet[7] = 0xb0;
        packet[8] = 0xff;
        let original = packet;
        assert!(!rewrite_buffer(&mut packet, 12));
        assert_eq!(packet, original);
    }

    #[test]
    fn rewrites_each_packet_in_a_multi_packet_buffer() {
        let first = packet_with_section(&pat_section(&[11, 12], 0), None);
        let second = packet_with_section(&pat_section(&[12, 13], 0), None);
        let mut buffer = [0u8; TS_PACKET_SIZE * 2];
        buffer[..TS_PACKET_SIZE].copy_from_slice(&first);
        buffer[TS_PACKET_SIZE..].copy_from_slice(&second);
        assert!(rewrite_buffer(&mut buffer, 12));
        assert_eq!(entries(buffer[..TS_PACKET_SIZE].try_into().unwrap()), [12]);
        assert_eq!(entries(buffer[TS_PACKET_SIZE..].try_into().unwrap()), [12]);
    }

    #[test]
    fn absent_program_leaves_an_empty_pat() {
        let mut packet = packet_with_section(&pat_section(&[0, 11], 0), None);
        assert!(rewrite_buffer(&mut packet, 12));
        assert!(entries(&packet).is_empty());
    }

    // The NIT PID is not part of the selected program, so tsparse drops it. Advertising it
    // would leave the same dangling reference the rewrite exists to remove.
    #[test]
    fn drops_the_nit_entry() {
        let mut packet = packet_with_section(&pat_section(&[0, 11, 12], 0), None);
        assert!(rewrite_buffer(&mut packet, 12));
        assert_eq!(entries(&packet), [12]);
    }

    #[test]
    fn leaves_multi_section_pat_untouched() {
        let mut packet = packet_with_section(&pat_section(&[11, 12], 1), None);
        let original = packet;
        assert!(!rewrite_buffer(&mut packet, 12));
        assert_eq!(packet, original);
    }

    #[test]
    fn leaves_transport_error_packet_untouched() {
        let mut packet = packet_with_section(&pat_section(&[11, 12], 0), None);
        packet[1] |= 0x80;
        let original = packet;
        assert!(!rewrite_buffer(&mut packet, 12));
        assert_eq!(packet, original);
    }

    #[test]
    fn leaves_packet_without_payload_untouched() {
        let mut packet = packet_with_section(&pat_section(&[11, 12], 0), None);
        // Adaptation field only, no payload.
        packet[3] = 0x20;
        let original = packet;
        assert!(!rewrite_buffer(&mut packet, 12));
        assert_eq!(packet, original);
    }

    #[test]
    fn leaves_packet_with_reserved_adaptation_control_untouched() {
        let mut packet = packet_with_section(&pat_section(&[11, 12], 0), None);
        packet[3] = 0x00;
        let original = packet;
        assert!(!rewrite_buffer(&mut packet, 12));
        assert_eq!(packet, original);
    }

    #[test]
    fn leaves_packet_without_section_start_untouched() {
        let mut packet = packet_with_section(&pat_section(&[11, 12], 0), None);
        // Clear payload_unit_start_indicator: this packet continues a section.
        packet[1] = 0x00;
        let original = packet;
        assert!(!rewrite_buffer(&mut packet, 12));
        assert_eq!(packet, original);
    }

    #[test]
    fn leaves_oversized_adaptation_field_untouched() {
        let mut packet = packet_with_section(&pat_section(&[11, 12], 0), Some(4));
        packet[4] = 250;
        let original = packet;
        assert!(!rewrite_buffer(&mut packet, 12));
        assert_eq!(packet, original);
    }

    #[test]
    fn leaves_pointer_field_past_the_packet_untouched() {
        let mut packet = packet_with_section(&pat_section(&[11, 12], 0), None);
        packet[4] = 250;
        let original = packet;
        assert!(!rewrite_buffer(&mut packet, 12));
        assert_eq!(packet, original);
    }

    #[test]
    fn leaves_non_pat_table_id_untouched() {
        let mut packet = packet_with_section(&pat_section(&[11, 12], 0), None);
        packet[5] = 0x02;
        let original = packet;
        assert!(!rewrite_buffer(&mut packet, 12));
        assert_eq!(packet, original);
    }

    #[test]
    fn leaves_short_form_section_untouched() {
        let mut packet = packet_with_section(&pat_section(&[11, 12], 0), None);
        // Clear section_syntax_indicator.
        packet[6] &= 0x7f;
        let original = packet;
        assert!(!rewrite_buffer(&mut packet, 12));
        assert_eq!(packet, original);
    }

    #[test]
    fn leaves_section_with_bad_reserved_bits_untouched() {
        let mut packet = packet_with_section(&pat_section(&[11, 12], 0), None);
        packet[6] &= 0xcf;
        let original = packet;
        assert!(!rewrite_buffer(&mut packet, 12));
        assert_eq!(packet, original);
    }

    #[test]
    fn leaves_section_with_bad_crc_untouched() {
        let mut packet = packet_with_section(&pat_section(&[11, 12], 0), None);
        let last = 5 + 3 + 9 + 2 * 4 - 1;
        packet[last] ^= 0xff;
        let original = packet;
        assert!(!rewrite_buffer(&mut packet, 12));
        assert_eq!(packet, original);
    }

    #[test]
    fn leaves_entry_with_bad_reserved_bits_untouched() {
        let mut section = pat_section(&[11, 12], 0);
        // Corrupt the reserved bits of the first program entry, then repair the CRC so the
        // section only fails on the entry check.
        section[10] &= 0x1f;
        let body_len = section.len() - 4;
        let crc = mpeg_crc32(&section[..body_len]);
        section[body_len..].copy_from_slice(&crc.to_be_bytes());
        let mut packet = packet_with_section(&section, None);
        let original = packet;
        assert!(!rewrite_buffer(&mut packet, 12));
        assert_eq!(packet, original);
    }

    // The probe is what production actually installs, so exercise it on a real pad rather than
    // only calling the rewrite helper directly.
    #[test]
    fn probe_rewrites_buffers_flowing_through_the_pad() {
        let _ = gst::init();

        let template = gst::PadTemplate::new(
            "src",
            gst::PadDirection::Src,
            gst::PadPresence::Always,
            &gst::Caps::new_any(),
        )
        .expect("pad template");
        let pad = gst::Pad::builder_from_template(&template).build();
        pad.set_active(true).expect("pad activates");

        install_probe(&pad, 12);

        let seen: Arc<Mutex<Vec<u8>>> = Arc::new(Mutex::new(Vec::new()));
        let captured = Arc::clone(&seen);
        pad.add_probe(gst::PadProbeType::BUFFER, move |_pad, info| {
            if let Some(buffer) = info.buffer() {
                if let Ok(map) = buffer.map_readable() {
                    captured
                        .lock()
                        .expect("lock")
                        .extend_from_slice(map.as_slice());
                }
            }
            gst::PadProbeReturn::Drop
        });

        let _ = pad.push_event(gst::event::StreamStart::new("test"));
        let _ = pad.push_event(gst::event::Segment::new(&gst::FormattedSegment::<
            gst::format::Bytes,
        >::new()));

        let packet = packet_with_section(&pat_section(&[11, 12], 0), None);
        let buffer = gst::Buffer::from_slice(packet);
        let _ = pad.push(buffer);

        let seen = seen.lock().expect("lock");
        assert_eq!(seen.len(), TS_PACKET_SIZE);
        let rewritten: [u8; TS_PACKET_SIZE] = seen.as_slice().try_into().expect("one packet");
        assert_eq!(entries(&rewritten), [12]);
    }

    #[test]
    fn leaves_misaligned_buffer_untouched() {
        let mut buffer = vec![0u8; TS_PACKET_SIZE + 1];
        let original = buffer.clone();
        assert!(!rewrite_buffer(&mut buffer, 12));
        assert_eq!(buffer, original);
    }
}
