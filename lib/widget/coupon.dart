import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:backend/models/coupon_model.dart' as CouponModel;
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart'; // Import the correct model

class Coupon extends StatefulWidget {
  final CouponModel.Coupon coupon; // Use the correct model type

  const Coupon({super.key, required this.coupon});

  @override
  State<Coupon> createState() => _CouponState();
}

class _CouponState extends State<Coupon> {
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      child: SizedBox(
        child: Card(
          shadowColor: Colors.black,
          elevation: 0,
          color: const Color.fromARGB(127, 239, 224, 213),
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: ListTile(
            
            title: SizedBox(
              height: 65,
              child: CachedNetworkImage(imageUrl: widget.coupon.imageURL),
            ), // Display image from URL
            // Display the coupon name
            subtitle: Center(
                child: Padding(
              padding: const EdgeInsets.all(4.0),
              child: Text(
                widget.coupon.description,
                style: TextStyle(
                    color: Colors.black,
                    fontSize: 16, // Adjust font size as needed

                    fontFamily: GoogleFonts.kanit().fontFamily,
                    fontWeight: FontWeight.w100),
              ),
            )), // Display the description
            // Remove the onTap and its contents, which appear to be unrelated
          ),
        ),
      ),
      onTap: () => launchUrl(Uri.parse(widget.coupon.link)),
    );
  }
}
