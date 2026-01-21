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
    // Implement reading logic based on your model's properties
    // ...
    return GroupInformation(
      groupId: reader.readString(),
      id: reader.readString(),
      departureDate: reader.read() as DateTime,
      returnDate: reader.read() as DateTime,
      departureFrom: reader.readString(),
      returnTo: reader.readString(),
      members: (reader.readList()).cast<GroupMember>(),
      guides: (reader.readList()).cast<Guide>(),
      timelineEvents: (reader.readList()).cast<TimelineEvent>(),
      packinglistCategories: (reader.readList()).cast<PackinglistCategories>(),
      agencyCode: reader.readString(),
      flights: (reader.readList() as List?)?.cast<FlightModel>(),
      emergencyPhone: reader.readString(),
      bureauName: reader.readString(),
      coupons: (reader.readList() as List?)?.cast<Coupon>(),
      flightHome: reader.readBool(),
      flightAway: reader.readBool(),
      messages: (reader.readList() as List?)?.cast<Message>(),
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
      phoneNumber: reader.readInt(),
    );
  }

  @override
  void write(BinaryWriter writer, GroupMember obj) {
    writer.writeString(obj.name);
    writer.writeString(obj.email);
    writer.writeInt(obj.phoneNumber);
  }
}

class GuideAdapter extends TypeAdapter<Guide> {
  @override
  final int typeId = 2;

  @override
  Guide read(BinaryReader reader) {
    return Guide(
      name: reader.readString(),
      phoneNumber: reader.readInt(),
    );
  }

  @override
  void write(BinaryWriter writer, Guide obj) {
    writer.writeString(obj.name);
    writer.writeInt(obj.phoneNumber);
  }
}
