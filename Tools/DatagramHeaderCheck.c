#include "DatagramHeader.h"
#include <assert.h>

int main(void) {
    // Flight envelope can carry fragments; a Racing header never sets that bit.
    assert(DatagramSequenceWord(7, true, false) == 0x80000007u);
    assert(DatagramSequenceWord(7, true, true) == 0xc0000007u);
    assert(DatagramSequenceWord(0x40000011u, false, false) == 0x11u);
    assert(DatagramOutOfBandMarker() == 0xffffffffu);

    DatagramHeader racing = DatagramDecodeHeader(0x80000007u, 0x80000003u);
    assert(racing.sequence == 7 && racing.acknowledged == 3);
    assert(racing.reliable && racing.reliableAcknowledged && !racing.fragmented);

    DatagramHeader flight = DatagramDecodeHeader(0x40000007u, 0x00000003u);
    assert(flight.sequence == 7 && flight.acknowledged == 3);
    assert(!flight.reliable && !flight.reliableAcknowledged && flight.fragmented);
}
