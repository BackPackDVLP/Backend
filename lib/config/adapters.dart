import 'package:backend/models/flight_model.dart';
import 'package:backend/models/group_information_model.dart';
import 'package:backend/models/group_members_model.dart';
import 'package:backend/models/guide_model.dart';
import 'package:backend/models/message_model.dart';
import 'package:backend/models/packinglist_model.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/timeline_event_model.dart';
import 'package:backend/models/coupon_model.dart';

class GroupInformationAdapter extends TypeAdapter<GroupInformation> {
  @override
  final int typeId = 0; // Assign a unique type ID

  @override
  GroupInformation read(BinaryReader reader) {
    final groupId = reader.readString();
    final id = reader.readString();
    final departureDate = reader.read() as DateTime;
    final returnDate = reader.read() as DateTime;
    final departureFrom = reader.readString();
    final returnTo = reader.readString();
    final members = (reader.readList()).cast<GroupMember>();
    final guides = (reader.readList()).cast<Guide>();
    final timelineEvents = (reader.readList()).cast<TimelineEvent>();
    final packinglistCategories =
        (reader.readList()).cast<PackinglistCategories>();
    final agencyCode = reader.readString();
    final flights = (reader.readList() as List?)?.cast<FlightModel>();
    final emergencyPhone = reader.readString();
    final bureauName = reader.readString();
    final coupons = (reader.readList() as List?)?.cast<Coupon>();
    final flightHome = reader.readBool();
    final flightAway = reader.readBool();
    final messages = (reader.readList() as List?)?.cast<Message>();
    // Appended later — entries cached before these existed simply end
    // here, so only read them when there are bytes left.
    final hasExtras = reader.availableBytes > 0;
    final groupName = hasExtras ? reader.read() as String? : null;
    final isTemplate = hasExtras ? reader.read() as bool? : null;
    final beforeDepartureItems =
        hasExtras ? (reader.read() as List?)?.cast<String>() : null;
    final mapEnabled = hasExtras ? reader.readBool() : false;

    return GroupInformation(
      groupId: groupId,
      id: id,
      departureDate: departureDate,
      returnDate: returnDate,
      departureFrom: departureFrom,
      returnTo: returnTo,
      members: members,
      guides: guides,
      timelineEvents: timelineEvents,
      packinglistCategories: packinglistCategories,
      agencyCode: agencyCode,
      flights: flights,
      emergencyPhone: emergencyPhone,
      bureauName: bureauName,
      coupons: coupons,
      flightHome: flightHome,
      flightAway: flightAway,
      messages: messages,
      groupName: groupName,
      isTemplate: isTemplate,
      beforeDepartureItems: beforeDepartureItems,
      mapEnabled: mapEnabled,
    );
  }

  @override
  void write(BinaryWriter writer, GroupInformation obj) {
    // Implement writing logic based on your model's properties
    writer.writeString(obj.groupId);
    writer.writeString(obj.id);
    writer.write(obj.departureDate);
    writer.write(obj.returnDate);
    writer.writeString(obj.departureFrom);
    writer.writeString(obj.returnTo);
    writer.writeList(obj.members);
    writer.writeList(obj.guides);
    writer.writeList(obj.timelineEvents);
    writer.writeList(obj.packinglistCategories);
    writer.writeString(obj.agencyCode);
    writer.writeList(obj.flights ?? []);
    writer.writeString(obj.emergencyPhone ?? '');
    writer.writeString(obj.bureauName);
    writer.writeList(obj.coupons ?? []);
    writer.writeBool(obj.flightHome);
    writer.writeBool(obj.flightAway);
    writer.writeList(obj.messages ?? []);
    writer.write(obj.groupName);
    writer.write(obj.isTemplate);
    writer.write(obj.beforeDepartureItems);
    writer.writeBool(obj.mapEnabled);
  }
}

class GroupMemberAdapter extends TypeAdapter<GroupMember> {
  @override
  final int typeId = 1;

  @override
  GroupMember read(BinaryReader reader) {
    return GroupMember(
      name: reader.readString(),
      email: reader.readString(),
      phoneNumber: reader.readString(),
      whatsappNumber: reader.readString(),
    );
  }

  @override
  void write(BinaryWriter writer, GroupMember obj) {
    writer.writeString(obj.name);
    writer.writeString(obj.email);
    writer.writeString(obj.phoneNumber);
    writer.writeString(obj.whatsappNumber);
  }
}

class GuideAdapter extends TypeAdapter<Guide> {
  @override
  final int typeId = 2;

  @override
  Guide read(BinaryReader reader) {
    return Guide(
      name: reader.readString(),
      phoneNumber: reader.readString(),
      whatsappNumber: reader.readString(),
      email: reader.readString(),
      title: reader.readString(),
    );
  }

  @override
  void write(BinaryWriter writer, Guide obj) {
    writer.writeString(obj.name);
    writer.writeString(obj.phoneNumber);
    writer.writeString(obj.whatsappNumber);
    writer.writeString(obj.email);
    writer.writeString(obj.title);
  }
}
